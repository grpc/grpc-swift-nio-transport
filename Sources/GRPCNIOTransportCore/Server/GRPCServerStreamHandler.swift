/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package import GRPCCore
package import NIOCore
package import NIOHTTP2

@available(gRPCSwiftNIOTransport 2.0, *)
package final class GRPCServerStreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
  package typealias InboundIn = HTTP2Frame.FramePayload
  package typealias InboundOut = RPCRequestPart<GRPCNIOTransportBytes>

  package typealias OutboundIn = RPCResponsePart<GRPCNIOTransportBytes>
  package typealias OutboundOut = HTTP2Frame.FramePayload

  private var stateMachine: GRPCStreamStateMachine
  private let eventLoop: any EventLoop

  private var isReading = false
  private var flushPending = false
  private var isCancelled = false

  // We buffer the final status + trailers to avoid reordering issues (i.e.,
  // if there are messages still not written into the channel because flush has
  // not been called, but the server sends back trailers).
  private var pendingTrailers:
    (trailers: HTTP2Frame.FramePayload, promise: EventLoopPromise<Void>?)?

  private let methodDescriptorPromise: EventLoopPromise<MethodDescriptor>

  private var cancellationHandle: Optional<ServerContext.RPCCancellationHandle>

  package let connectionManagementHandler: ServerConnectionManagementHandler.SyncView

  // Existential errors unconditionally allocate, avoid this per-use allocation by doing it
  // statically.
  private static let handlerRemovedBeforeDescriptorResolved: any Error = RPCError(
    code: .unavailable,
    message: "RPC stream was closed before we got any Metadata."
  )

  package init(
    scheme: Scheme,
    acceptedEncodings: CompressionAlgorithmSet,
    maxPayloadSize: Int,
    methodDescriptorPromise: EventLoopPromise<MethodDescriptor>,
    eventLoop: any EventLoop,
    connectionManagementHandler: ServerConnectionManagementHandler.SyncView,
    cancellationHandler: ServerContext.RPCCancellationHandle? = nil,
    skipStateMachineAssertions: Bool = false
  ) {
    self.stateMachine = .init(
      configuration: .server(.init(scheme: scheme, acceptedEncodings: acceptedEncodings)),
      maxPayloadSize: maxPayloadSize,
      skipAssertions: skipStateMachineAssertions
    )
    self.methodDescriptorPromise = methodDescriptorPromise
    self.cancellationHandle = cancellationHandler
    self.eventLoop = eventLoop
    self.connectionManagementHandler = connectionManagementHandler
  }

  package func setCancellationHandle(_ handle: ServerContext.RPCCancellationHandle) {
    if self.eventLoop.inEventLoop {
      self.syncSetCancellationHandle(handle)
    } else {
      let loopBoundSelf = NIOLoopBound(self, eventLoop: self.eventLoop)
      self.eventLoop.execute {
        loopBoundSelf.value.syncSetCancellationHandle(handle)
      }
    }
  }

  private func syncSetCancellationHandle(_ handle: ServerContext.RPCCancellationHandle) {
    assert(self.cancellationHandle == nil, "\(#function) must only be called once")

    if self.isCancelled {
      handle.cancel()
    } else {
      self.cancellationHandle = handle
    }
  }

  private func cancelRPC() {
    if let handle = self.cancellationHandle.take() {
      handle.cancel()
    } else {
      self.isCancelled = true
    }
  }
}

// - MARK: ChannelInboundHandler

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCServerStreamHandler {
  package func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelShouldQuiesceEvent:
      self.cancelRPC()
    default:
      ()
    }

    context.fireUserInboundEventTriggered(event)
  }

  package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    self.isReading = true
    let frame = self.unwrapInboundIn(data)
    switch frame {
    case .data(let frameData):
      let endStream = frameData.endStream
      switch frameData.data {
      case .byteBuffer(let buffer):
        do {
          switch try self.stateMachine.receive(buffer: buffer, endStream: endStream) {
          case .endRPCAndForwardErrorStatus_clientOnly:
            preconditionFailure(
              "OnBufferReceivedAction.endRPCAndForwardErrorStatus should never be returned for the server."
            )

          case .forwardErrorAndClose_serverOnly(let error):
            context.fireErrorCaught(error)
            context.close(mode: .all, promise: nil)

          case .readInbound:
            loop: while true {
              switch self.stateMachine.nextInboundMessage() {
              case .receiveMessage(let message):
                let wrapped = GRPCNIOTransportBytes(message)
                context.fireChannelRead(self.wrapInboundOut(.message(wrapped)))

              case .awaitMoreMessages:
                break loop

              case .noMoreMessages:
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                break loop
              }
            }

          case .doNothing:
            ()
          }
        } catch let invalidState {
          let error = RPCError(invalidState)
          context.fireErrorCaught(error)
        }

      case .fileRegion:
        preconditionFailure("Unexpected IOData.fileRegion")
      }

    case .headers(let headers):
      do {
        let action = try self.stateMachine.receive(
          headers: headers.headers,
          endStream: headers.endStream
        )
        switch action {
        case .receivedMetadata(let metadata, let methodDescriptor):
          if let methodDescriptor = methodDescriptor {
            self.methodDescriptorPromise.succeed(methodDescriptor)
            context.fireChannelRead(self.wrapInboundOut(.metadata(metadata)))
          } else {
            assertionFailure("Method descriptor should have been present if we received metadata.")
          }

        case .rejectRPC_serverOnly(let trailers):
          self.flushPending = true
          self.methodDescriptorPromise.fail(
            RPCError(
              code: .unavailable,
              message: "RPC was rejected."
            )
          )
          let response = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
          context.write(self.wrapOutboundOut(response), promise: nil)

        case .receivedStatusAndMetadata_clientOnly:
          assertionFailure("Unexpected action")

        case .protocolViolation_serverOnly:
          context.writeAndFlush(self.wrapOutboundOut(.rstStream(.protocolError)), promise: nil)
          context.close(promise: nil)

        case .doNothing:
          ()
        }
      } catch let invalidState {
        let error = RPCError(invalidState)
        context.fireErrorCaught(error)
      }

    case .rstStream:
      self.handleUnexpectedInboundClose(context: context, reason: .streamReset)

    case .ping, .goAway, .priority, .settings, .pushPromise, .windowUpdate,
      .alternativeService, .origin:
      ()
    }
  }

  package func channelReadComplete(context: ChannelHandlerContext) {
    self.isReading = false
    if self.flushPending {
      self.flushPending = false
      context.flush()
    }
    context.fireChannelReadComplete()
  }

  package func handlerRemoved(context: ChannelHandlerContext) {
    self.stateMachine.tearDown()
    self.methodDescriptorPromise.fail(Self.handlerRemovedBeforeDescriptorResolved)
  }

  package func channelInactive(context: ChannelHandlerContext) {
    self.handleUnexpectedInboundClose(context: context, reason: .channelInactive)
    context.fireChannelInactive()
  }

  package func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.handleUnexpectedInboundClose(context: context, reason: .errorThrown(error))
  }

  private func handleUnexpectedInboundClose(
    context: ChannelHandlerContext,
    reason: GRPCStreamStateMachine.UnexpectedInboundCloseReason
  ) {
    switch self.stateMachine.unexpectedInboundClose(reason: reason) {
    case .fireError_serverOnly(let wrappedError):
      self.cancelRPC()
      context.fireErrorCaught(wrappedError)
    case .doNothing:
      ()
    case .forwardStatus_clientOnly:
      assertionFailure(
        "`forwardStatus` should only happen on the client side, never on the server."
      )
    }
  }
}

// - MARK: ChannelOutboundHandler

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCServerStreamHandler {
  package func write(
    context: ChannelHandlerContext,
    data: NIOAny,
    promise: EventLoopPromise<Void>?
  ) {
    let frame = self.unwrapOutboundIn(data)
    switch frame {
    case .metadata(let metadata):
      do {
        self.flushPending = true
        let headers = try self.stateMachine.send(metadata: metadata)
        context.write(self.wrapOutboundOut(.headers(.init(headers: headers))), promise: promise)
        self.connectionManagementHandler.wroteHeadersFrame()
      } catch let invalidState {
        let error = RPCError(invalidState)
        promise?.fail(error)
        context.fireErrorCaught(error)
      }

    case .message(let message):
      do {
        try self.stateMachine.send(message: message.buffer, promise: promise)
        self.connectionManagementHandler.wroteDataFrame()
      } catch let invalidState {
        let error = RPCError(invalidState)
        promise?.fail(error)
        context.fireErrorCaught(error)
      }

    case .status(let status, let metadata):
      do {
        let headers = try self.stateMachine.send(status: status, metadata: metadata)
        let response = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
        self.pendingTrailers = (response, promise)
      } catch let invalidState {
        let error = RPCError(invalidState)
        promise?.fail(error)
        context.fireErrorCaught(error)
      }
    }
  }

  package func flush(context: ChannelHandlerContext) {
    if self.isReading {
      // We don't want to flush yet if we're still in a read loop.
      return
    }

    do {
      loop: while true {
        switch try self.stateMachine.nextOutboundFrame() {
        case .sendFrame(let byteBuffer, let promise):
          self.flushPending = true
          context.write(
            self.wrapOutboundOut(.data(.init(data: .byteBuffer(byteBuffer)))),
            promise: promise
          )

        case .noMoreMessages:
          if let pendingTrailers = self.pendingTrailers {
            self.flushPending = true
            self.pendingTrailers = nil
            context.write(
              self.wrapOutboundOut(pendingTrailers.trailers),
              promise: pendingTrailers.promise
            )
          }
          break loop

        case .awaitMoreMessages:
          break loop

        case .closeAndFailPromise(let promise, let error):
          context.close(mode: .all, promise: nil)
          promise?.fail(error)
        }
      }

      if self.flushPending {
        self.flushPending = false
        context.flush()
      }
    } catch let invalidState {
      let error = RPCError(invalidState)
      context.fireErrorCaught(error)
    }
  }
}
