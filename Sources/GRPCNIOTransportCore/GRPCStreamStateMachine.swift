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

internal import GRPCCore
internal import NIOCore
internal import NIOHPACK
internal import NIOHTTP1
internal import NIOHTTP2

package enum Scheme: String {
  case http
  case https
}

@available(gRPCSwiftNIOTransport 2.0, *)
enum GRPCStreamStateMachineConfiguration {
  case client(ClientConfiguration)
  case server(ServerConfiguration)

  struct ClientConfiguration {
    var methodDescriptor: MethodDescriptor
    var scheme: Scheme
    var authority: String?
    var outboundEncoding: CompressionAlgorithm
    var acceptedEncodings: CompressionAlgorithmSet

    init(
      methodDescriptor: MethodDescriptor,
      scheme: Scheme,
      authority: String?,
      outboundEncoding: CompressionAlgorithm,
      acceptedEncodings: CompressionAlgorithmSet
    ) {
      self.methodDescriptor = methodDescriptor
      self.scheme = scheme
      self.authority = authority
      self.outboundEncoding = outboundEncoding
      self.acceptedEncodings = acceptedEncodings.union(.none)
    }

    var delayWritesUntilHalfClosed: Bool {
      methodDescriptor.type.isKnownUnaryRequest
    }
  }

  struct ServerConfiguration {
    var scheme: Scheme
    var acceptedEncodings: CompressionAlgorithmSet

    init(scheme: Scheme, acceptedEncodings: CompressionAlgorithmSet) {
      self.scheme = scheme
      self.acceptedEncodings = acceptedEncodings.union(.none)
    }
  }
}

/// The state of a stream.
///
/// Valid states are the product of two independent dimensions, client and server. Each dimension
/// can only make foward progress through the following states: idle → open → closed.
///
/// There are two terminal states:
/// - clientClosedServerClosed: the stream completed cleanly.
/// - poisoned: the stream failed to complete because of some unrecoverable error.
///
/// There are three kinds of invalid operation:
/// 1. `UnreachableTransition`. The calling code has a bug: it invoked an operation that was thought
///    to be structurally impossible in the current state. This represents API misuse or an
///    incorrect assumption; i.e. the issue lies in gRPC. When this happens the state machine enters
///    the poisoned state and throws `UnreachableTransition`. Debug builds also trigger
///    an `assertionFailure`.
/// 2. Protocol errors. The remote peer violated gRPC/HTTP2 semantics. The triggering operation
///    surfaces an appropriate error to the caller (this is situation dependent) and the state
///    machine enters the poisoned state. This represents an issue with the remote peer (or
///    intermediary).
/// 3. Silent drops. A small number of operations are legitimately ignored: 1xx HTTP status codes
///    (spec-mandated), server discarding client data after the server has already closed (normal
///    gRPC early-close behaviour), closing outbound more than once (as independent close mechanisms
///    can race), and inbound operations received when already in the error state.
@available(gRPCSwiftNIOTransport 2.0, *)
private enum GRPCStreamStateMachineState {
  case clientIdleServerIdle(ClientIdleServerIdleState)
  case clientOpenServerIdle(ClientOpenServerIdleState)
  case clientOpenServerOpen(ClientOpenServerOpenState)
  case clientOpenServerClosed(ClientOpenServerClosedState)
  case clientClosedServerIdle(ClientClosedServerIdleState)
  case clientClosedServerOpen(ClientClosedServerOpenState)
  case clientClosedServerClosed(ClientClosedServerClosedState)
  /// The poisoned state: something happened that means the RPC can't make forward progress.
  ///
  /// All actions in this state are no-ops.
  case poisoned(Poisoned)

  /// Temporary state to avoid accidental CoWs.
  case _modifying

  var name: String {
    switch self {
    case .clientIdleServerIdle:
      return "clientIdleServerIdle"
    case .clientOpenServerIdle:
      return "clientOpenServerIdle"
    case .clientOpenServerOpen:
      return "clientOpenServerOpen"
    case .clientOpenServerClosed:
      return "clientOpenServerClosed"
    case .clientClosedServerIdle:
      return "clientClosedServerIdle"
    case .clientClosedServerOpen:
      return "clientClosedServerOpen"
    case .clientClosedServerClosed:
      return "clientClosedServerClosed"
    case .poisoned:
      return "poisoned"
    case ._modifying:
      return "_modifying"
    }
  }

  struct ClientIdleServerIdleState {
    let maxPayloadSize: Int
  }

  struct ClientOpenServerIdleState {
    let maxPayloadSize: Int
    var framer: GRPCMessageFramer
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    // The deframer must be optional because the client will not have one configured
    // until the server opens and sends a grpc-encoding header.
    // It will be present for the server though, because even though it's idle,
    // it can still receive compressed messages from the client.
    var deframer: GRPCMessageDeframer?
    var decompressor: Zlib.Decompressor?

    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>

    // Store the headers received from the remote peer, its storage can be reused when sending
    // headers back to the remote peer.
    var headers: HPACKHeaders

    init(
      previousState: ClientIdleServerIdleState,
      compressor: Zlib.Compressor?,
      outboundCompression: CompressionAlgorithm,
      framer: GRPCMessageFramer,
      decompressor: Zlib.Decompressor?,
      deframer: GRPCMessageDeframer?,
      headers: HPACKHeaders
    ) {
      self.maxPayloadSize = previousState.maxPayloadSize
      self.compressor = compressor
      self.outboundCompression = outboundCompression
      self.framer = framer
      self.decompressor = decompressor
      self.deframer = deframer
      self.inboundMessageBuffer = .init()
      self.headers = headers
    }
  }

  struct ClientOpenServerOpenState {
    var framer: GRPCMessageFramer
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    var deframer: GRPCMessageDeframer
    var decompressor: Zlib.Decompressor?

    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>

    // Store the headers received from the remote peer, its storage can be reused when sending
    // headers back to the remote peer.
    var headers: HPACKHeaders

    init(
      previousState: ClientOpenServerIdleState,
      deframer: GRPCMessageDeframer,
      decompressor: Zlib.Decompressor?
    ) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression

      self.deframer = deframer
      self.decompressor = decompressor

      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.headers = previousState.headers
    }
  }

  struct ClientOpenServerClosedState {
    var framer: GRPCMessageFramer?
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    let deframer: GRPCMessageDeframer?
    var decompressor: Zlib.Decompressor?

    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>

    // This transition should only happen on the server-side when, upon receiving
    // initial client metadata, some of the headers are invalid and we must reject
    // the RPC.
    // We will mark the client as open (because it sent initial metadata albeit
    // invalid) but we'll close the server, meaning all future messages sent from
    // the client will be ignored. Because of this, we won't need to frame or
    // deframe any messages, as we won't be reading or writing any messages.
    init(previousState: ClientIdleServerIdleState) {
      self.framer = nil
      self.compressor = nil
      self.outboundCompression = .none
      self.deframer = nil
      self.decompressor = nil
      self.inboundMessageBuffer = .init()
    }

    init(previousState: ClientOpenServerOpenState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.deframer = previousState.deframer
      self.decompressor = previousState.decompressor
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
    }

    init(previousState: ClientOpenServerIdleState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      // The server went directly from idle to closed - this means it sent a
      // trailers-only response:
      // - if we're the client, the previous state was a nil deframer, but that
      // is okay because we don't need a deframer as the server won't be sending
      // any messages;
      // - if we're the server, we'll keep whatever deframer we had.
      self.deframer = previousState.deframer
      self.decompressor = previousState.decompressor
    }
  }

  struct ClientClosedServerIdleState {
    let maxPayloadSize: Int
    var framer: GRPCMessageFramer
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    let deframer: GRPCMessageDeframer?
    var decompressor: Zlib.Decompressor?

    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>
    var hasSentEndStream: Bool

    // Store the headers received from the remote peer, its storage can be reused when sending
    // headers back to the remote peer.
    var headers: HPACKHeaders

    /// This transition should only happen on the client-side.
    /// It can happen if the request times out before the client outbound can be opened, or if the stream is
    /// unexpectedly closed for some other reason on the client before it can transition to open.
    init(previousState: ClientIdleServerIdleState) {
      self.maxPayloadSize = previousState.maxPayloadSize
      // We don't need a compressor since we won't be sending any messages.
      self.framer = GRPCMessageFramer()
      self.compressor = nil
      self.outboundCompression = .none

      // We haven't received anything from the server.
      self.deframer = nil
      self.decompressor = nil

      self.inboundMessageBuffer = .init()
      self.hasSentEndStream = false
      self.headers = [:]
    }

    /// This transition should only happen on the server-side.
    /// We are closing the client as soon as it opens (i.e., endStream was set when receiving the client's
    /// initial metadata). We don't need to know a decompression algorithm, since we won't receive
    /// any more messages from the client anyways, as it's closed.
    init(
      previousState: ClientIdleServerIdleState,
      compressionAlgorithm: CompressionAlgorithm,
      headers: HPACKHeaders
    ) {
      self.maxPayloadSize = previousState.maxPayloadSize

      if let zlibMethod = Zlib.Method(encoding: compressionAlgorithm) {
        self.compressor = Zlib.Compressor(method: zlibMethod)
        self.outboundCompression = compressionAlgorithm
      } else {
        self.compressor = nil
        self.outboundCompression = .none
      }
      self.framer = GRPCMessageFramer()
      // We don't need a deframer since we won't receive any messages from the
      // client: it's closed.
      self.deframer = nil
      self.inboundMessageBuffer = .init()
      self.hasSentEndStream = false
      self.headers = headers
    }

    init(previousState: ClientOpenServerIdleState) {
      self.maxPayloadSize = previousState.maxPayloadSize
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.deframer = previousState.deframer
      self.decompressor = previousState.decompressor
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = false
      self.headers = previousState.headers
    }
  }

  struct ClientClosedServerOpenState {
    var framer: GRPCMessageFramer
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    var deframer: GRPCMessageDeframer?
    var decompressor: Zlib.Decompressor?

    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>
    var hasSentEndStream: Bool

    // Store the headers received from the remote peer, its storage can be reused when sending
    // headers back to the remote peer.
    var headers: HPACKHeaders

    init(previousState: ClientOpenServerOpenState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.deframer = previousState.deframer
      self.decompressor = previousState.decompressor
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = false
      self.headers = previousState.headers
    }

    /// This should be called from the server path, as the deframer will already be configured in this scenario.
    init(previousState: ClientClosedServerIdleState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression

      // In the case of the server, we don't need to deframe/decompress any more
      // messages, since the client's closed.
      self.deframer = nil
      self.decompressor = nil

      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = previousState.hasSentEndStream
      self.headers = previousState.headers
    }

    /// This should only be called from the client path, as the deframer has not yet been set up.
    init(
      previousState: ClientClosedServerIdleState,
      decompressionAlgorithm: CompressionAlgorithm
    ) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression

      // In the case of the client, it will only be able to set up the deframer
      // after it receives the chosen encoding from the server.
      if let zlibMethod = Zlib.Method(encoding: decompressionAlgorithm) {
        self.decompressor = Zlib.Decompressor(method: zlibMethod)
      }

      self.deframer = GRPCMessageDeframer(
        maxPayloadSize: previousState.maxPayloadSize,
        decompressor: self.decompressor
      )

      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = previousState.hasSentEndStream
      self.headers = previousState.headers
    }
  }

  struct ClientClosedServerClosedState {
    // We still need the framer and compressor in case the server has closed
    // but its buffer is not yet empty and still needs to send messages out to
    // the client.
    var framer: GRPCMessageFramer?
    var compressor: Zlib.Compressor?
    var outboundCompression: CompressionAlgorithm

    // These are already deframed, so we don't need the deframer anymore.
    var inboundMessageBuffer: OneOrManyQueue<ByteBuffer>
    var hasSentEndStream: Bool

    // This transition should only happen on the server-side when, upon receiving
    // initial client metadata, some of the headers are invalid and we must reject
    // the RPC.
    // We will mark the client as closed (because it set the EOS flag, even if
    // the initial metadata was invalid) and we'll close the server too.
    // Because of this, we won't need to frame any messages, as we
    // won't be writing any messages.
    init(previousState: ClientIdleServerIdleState) {
      self.framer = nil
      self.compressor = nil
      self.outboundCompression = .none
      self.inboundMessageBuffer = .init()
      self.hasSentEndStream = false
    }

    init(previousState: ClientClosedServerOpenState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = previousState.hasSentEndStream
    }

    init(previousState: ClientClosedServerIdleState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = previousState.hasSentEndStream
    }

    init(previousState: ClientOpenServerClosedState) {
      self.framer = previousState.framer
      self.compressor = previousState.compressor
      self.outboundCompression = previousState.outboundCompression
      self.inboundMessageBuffer = previousState.inboundMessageBuffer
      self.hasSentEndStream = false
    }
  }

  struct Poisoned {
    enum Reason: CustomStringConvertible {
      /// gRPC or HTTP/2 semantics were not respected.
      case `protocol`
      /// A supposedly unreachable state was reached.
      case unreachableTransition(state: String, function: String)
      /// Unexpected inbound close.
      case unexpectedClose

      var description: String {
        switch self {
        case .protocol:
          return "gRPC or HTTP/2 protocol violation"
        case .unreachableTransition(let state, let function):
          return "an 'unreachable' transition was hit in the \(state) state (in \(function))"
        case .unexpectedClose:
          return "the stream was closed unexpectedly"
        }
      }
    }

    /// The reason the state was poisoned.
    var reason: Reason

    var rpcError: RPCError {
      RPCError(
        code: .internalError,
        message: "Stream is in an error state: \(self.reason)"
      )
    }

    init(previousState state: ClientIdleServerIdleState, reason: Reason) {
      self.reason = reason
    }

    init(previousState state: ClientOpenServerIdleState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
      state.decompressor?.end()
    }

    init(previousState state: ClientOpenServerOpenState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
      state.decompressor?.end()
    }

    init(previousState state: ClientOpenServerClosedState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
      state.decompressor?.end()
    }

    init(previousState state: ClientClosedServerIdleState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
      state.decompressor?.end()
    }

    init(previousState state: ClientClosedServerOpenState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
      state.decompressor?.end()
    }

    init(previousState state: ClientClosedServerClosedState, reason: Reason) {
      self.reason = reason
      state.compressor?.end()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
struct GRPCStreamStateMachine {
  private var state: GRPCStreamStateMachineState
  private var configuration: GRPCStreamStateMachineConfiguration
  private var skipAssertions: Bool

  /// The state transition isn't possible by construction.
  struct UnreachableTransition: Error {
    var message: String
    init(_ message: String) {
      self.message = message
    }
  }

  init(
    configuration: GRPCStreamStateMachineConfiguration,
    maxPayloadSize: Int,
    skipAssertions: Bool = false
  ) {
    self.state = .clientIdleServerIdle(.init(maxPayloadSize: maxPayloadSize))
    self.configuration = configuration
    self.skipAssertions = skipAssertions
  }

  enum OnSendMetadata {
    case write(HPACKHeaders)
    case failPromise(RPCError)
  }

  mutating func send(metadata: Metadata) throws(UnreachableTransition) -> OnSendMetadata {
    switch self.configuration {
    case .client(let clientConfiguration):
      return try self.clientSend(metadata: metadata, configuration: clientConfiguration)
    case .server(let serverConfiguration):
      return try self.serverSend(metadata: metadata, configuration: serverConfiguration)
    }
  }

  enum OnSendMessage {
    case nothing
    case succeedPromise
    case failPromise(RPCError)
  }

  mutating func send(
    message: ByteBuffer,
    promise: EventLoopPromise<Void>?
  ) throws(UnreachableTransition) -> OnSendMessage {
    switch self.configuration {
    case .client:
      try self.clientSend(message: message, promise: promise)
    case .server:
      try self.serverSend(message: message, promise: promise)
    }
  }

  mutating func closeOutbound() throws(UnreachableTransition) {
    switch self.configuration {
    case .client:
      try self.clientCloseOutbound()
    case .server:
      try self.unreachable("Server cannot call close: it must send status and trailers.")
    }
  }

  mutating func send(
    status: Status,
    metadata: Metadata
  ) throws(UnreachableTransition) -> OnServerSendStatus {
    switch self.configuration {
    case .client:
      try self.unreachable("Client cannot send status and trailer.")
    case .server:
      return try self.serverSend(
        status: status,
        customMetadata: metadata
      )
    }
  }

  enum OnMetadataReceived: Equatable {
    case receivedMetadata(Metadata, String?)
    case doNothing

    // Client-specific actions
    case receivedStatusAndMetadata_clientOnly(status: Status, metadata: Metadata)

    // Server-specific actions
    case rejectRPC_serverOnly(trailers: HPACKHeaders)
    case protocolViolation_serverOnly
  }

  mutating func receive(
    headers: HPACKHeaders,
    endStream: Bool
  ) throws(UnreachableTransition) -> OnMetadataReceived {
    switch self.configuration {
    case .client(let clientConfiguration):
      return try self.clientReceive(
        headers: headers,
        endStream: endStream,
        configuration: clientConfiguration
      )
    case .server(let serverConfiguration):
      return self.serverReceive(
        headers: headers,
        endStream: endStream,
        configuration: serverConfiguration
      )
    }
  }

  enum OnBufferReceivedAction: Equatable {
    case readInbound
    case doNothing

    // This will be returned when the server sends a data frame with EOS set.
    // This is invalid as per the protocol specification, because the server
    // can only close by sending trailers, not by setting EOS when sending
    // a message.
    case endRPCAndForwardErrorStatus_clientOnly(Status)

    case forwardErrorAndClose_serverOnly(RPCError)
  }

  mutating func receive(
    buffer: ByteBuffer,
    endStream: Bool
  ) -> OnBufferReceivedAction {
    switch self.configuration {
    case .client:
      return self.clientReceive(buffer: buffer, endStream: endStream)
    case .server:
      return self.serverReceive(buffer: buffer, endStream: endStream)
    }
  }

  /// The result of requesting the next outbound frame, which may contain multiple messages.
  enum OnNextOutboundFrame {
    /// Either the receiving party is closed, so we shouldn't send any more frames; or the sender is done
    /// writing messages (i.e. we are now closed).
    case noMoreMessages
    /// There isn't a frame ready to be sent, but we could still receive more messages, so keep trying.
    case awaitMoreMessages
    /// A frame is ready to be sent.
    case sendFrame(
      frame: ByteBuffer,
      endStream: Bool,
      promise: EventLoopPromise<Void>?
    )
    case closeAndFailPromise(EventLoopPromise<Void>?, RPCError)

    init(result: Result<ByteBuffer, RPCError>, endStream: Bool, promise: EventLoopPromise<Void>?) {
      switch result {
      case .success(let buffer):
        self = .sendFrame(frame: buffer, endStream: endStream, promise: promise)
      case .failure(let error):
        self = .closeAndFailPromise(promise, error)
      }
    }
  }

  mutating func nextOutboundFrame() throws(UnreachableTransition) -> OnNextOutboundFrame {
    let action: OnNextOutboundFrame

    switch self.state {
    case .clientIdleServerIdle:
      // This is unreachable by construction: the handler holding this state machine shouldn't
      // ask for more outbound messages unless it's successfully buffered one in the state machine.
      switch self.configuration {
      case .client:
        try self.unreachable("Client is not open yet.")
      case .server:
        try self.unreachable("Server is not open yet.")
      }

    case .clientOpenServerIdle(var state):
      switch self.configuration {
      case .client(let config):
        if config.delayWritesUntilHalfClosed {
          action = .awaitMoreMessages
        } else {
          self.state = ._modifying
          let next = state.framer.nextResult(compressor: state.compressor)
          self.state = .clientOpenServerIdle(state)

          if let next = next {
            action = OnNextOutboundFrame(
              result: next.result,
              endStream: false,
              promise: next.promise
            )
          } else {
            action = .awaitMoreMessages
          }
        }

      case .server:
        // This is unreachable by construction: the handler holding this state machine shouldn't
        // ask for more outbound messages unless it's successfully buffered one in the state
        // machine.
        try self.unreachable("Server is not open yet.")
      }

    case .clientOpenServerOpen(var state):
      switch self.configuration {
      case .client(let config) where config.delayWritesUntilHalfClosed:
        // Early exit, wait for half close.
        action = .awaitMoreMessages

      case .client, .server:
        self.state = ._modifying
        let next = state.framer.nextResult(compressor: state.compressor)
        self.state = .clientOpenServerOpen(state)

        if let next = next {
          action = OnNextOutboundFrame(result: next.result, endStream: false, promise: next.promise)
        } else {
          action = .awaitMoreMessages
        }
      }

    case .clientClosedServerIdle(var state):
      switch self.configuration {
      case .client:
        self.state = ._modifying
        let next = state.framer.nextResult(compressor: state.compressor)

        if let next = next {
          // nextResult() drains all pending messages into a single buffer in one
          // call, so this batch is always the last one: endStream is always true.
          state.hasSentEndStream = true
          action = OnNextOutboundFrame(
            result: next.result,
            endStream: true,
            promise: next.promise
          )
        } else if state.hasSentEndStream {
          action = .noMoreMessages
        } else {
          // Send an empty frame with end-stream
          state.hasSentEndStream = true
          action = .sendFrame(frame: ByteBuffer(), endStream: true, promise: nil)
        }

        self.state = .clientClosedServerIdle(state)

      case .server:
        try self.unreachable("Server is not open yet.")
      }

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      let next = state.framer.nextResult(compressor: state.compressor)

      switch self.configuration {
      case .client:
        if let next = next {
          // nextResult() drains all pending messages into a single buffer in one
          // call, so this batch is always the last one: endStream is always true.
          state.hasSentEndStream = true
          action = OnNextOutboundFrame(
            result: next.result,
            endStream: true,
            promise: next.promise
          )
        } else if state.hasSentEndStream {
          action = .noMoreMessages
        } else {
          // Send an empty frame with end-stream
          state.hasSentEndStream = true
          action = .sendFrame(frame: ByteBuffer(), endStream: true, promise: nil)
        }
      case .server:
        if let next = next {
          action = OnNextOutboundFrame(
            result: next.result,
            endStream: false,
            promise: next.promise
          )
        } else {
          action = .awaitMoreMessages
        }
      }

      self.state = .clientClosedServerOpen(state)

    case .clientOpenServerClosed(var state):
      switch self.configuration {
      case .client:
        // No point in sending any more requests if the server is closed.
        action = .noMoreMessages

      case .server:
        self.state = ._modifying
        let next = state.framer?.nextResult(compressor: state.compressor)
        self.state = .clientOpenServerClosed(state)

        if let next = next {
          action = OnNextOutboundFrame(result: next.result, endStream: false, promise: next.promise)
        } else {
          action = .noMoreMessages
        }
      }

    case .clientClosedServerClosed(var state):
      switch self.configuration {
      case .client:
        // No point in sending any more requests if the server is closed.
        action = .noMoreMessages

      case .server:
        self.state = ._modifying
        let next = state.framer?.nextResult(compressor: state.compressor)
        self.state = .clientClosedServerClosed(state)

        if let next = next {
          action = OnNextOutboundFrame(result: next.result, endStream: false, promise: next.promise)
        } else {
          action = .noMoreMessages
        }
      }

    case .poisoned:
      // No point in sending any more requests if the stream is poisoned.
      action = .noMoreMessages

    case ._modifying:
      preconditionFailure()
    }

    return action
  }

  /// The result of requesting the next inbound message.
  enum OnNextInboundMessage: Equatable {
    /// The sender is done writing messages and there are no more messages to be received.
    case noMoreMessages
    /// There isn't a message ready to be sent, but we could still receive more, so keep trying.
    case awaitMoreMessages
    /// A message has been received.
    case receiveMessage(ByteBuffer)
  }

  mutating func nextInboundMessage() -> OnNextInboundMessage {
    switch self.configuration {
    case .client:
      return self.clientNextInboundMessage()
    case .server:
      return self.serverNextInboundMessage()
    }
  }

  mutating func tearDown() {
    switch self.state {
    case .clientIdleServerIdle:
      ()
    case .clientOpenServerIdle(let state):
      state.compressor?.end()
      state.decompressor?.end()
    case .clientOpenServerOpen(let state):
      state.compressor?.end()
      state.decompressor?.end()
    case .clientOpenServerClosed(let state):
      state.compressor?.end()
      state.decompressor?.end()
    case .clientClosedServerIdle(let state):
      state.compressor?.end()
      state.decompressor?.end()
    case .clientClosedServerOpen(let state):
      state.compressor?.end()
      state.decompressor?.end()
    case .clientClosedServerClosed(let state):
      state.compressor?.end()
    case .poisoned:
      ()
    case ._modifying:
      preconditionFailure()
    }
  }

  enum OnUnexpectedInboundClose {
    case forwardStatus_clientOnly(Status)
    case fireError_serverOnly(any Error)
    case doNothing

    init(serverCloseReason: UnexpectedInboundCloseReason) {
      switch serverCloseReason {
      case .streamReset, .channelInactive:
        self = .fireError_serverOnly(RPCError(serverCloseReason))
      case .errorThrown(let error):
        self = .fireError_serverOnly(error)
      }
    }
  }

  enum UnexpectedInboundCloseReason {
    case streamReset(HTTP2ErrorCode)
    case channelInactive
    case errorThrown(any Error)
  }

  mutating func unexpectedClose(
    reason: UnexpectedInboundCloseReason
  ) -> OnUnexpectedInboundClose {
    switch self.configuration {
    case .client:
      return self.clientUnexpectedClose(reason: reason)
    case .server:
      return self.serverUnexpectedClose(reason: reason)
    }
  }
}

// - MARK: Client

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCStreamStateMachine {
  private func makeClientHeaders(
    methodDescriptor: MethodDescriptor,
    scheme: Scheme,
    authority: String?,
    outboundEncoding: CompressionAlgorithm?,
    acceptedEncodings: CompressionAlgorithmSet,
    customMetadata: Metadata
  ) -> HPACKHeaders {
    var headers = HPACKHeaders()
    headers.reserveCapacity(7 + customMetadata.count)

    // Add required headers.
    // See https://github.com/grpc/grpc/blob/7f664c69b2a636386fbf95c16bc78c559734ce0f/doc/PROTOCOL-HTTP2.md#requests

    // The order is important here: reserved HTTP2 headers (those starting with `:`)
    // must come before all other headers.
    headers.add("POST", forKey: .method)
    headers.add(scheme.rawValue, forKey: .scheme)
    headers.add(methodDescriptor.path, forKey: .path)
    if let authority = authority {
      headers.add(authority, forKey: .authority)
    }

    // Add required gRPC headers.
    headers.add(ContentType.grpc.canonicalValue, forKey: .contentType)
    headers.add("trailers", forKey: .te)  // Used to detect incompatible proxies

    if let encoding = outboundEncoding, encoding != .none, let name = encoding.nameIfSupported {
      headers.add(name, forKey: .encoding)
    }

    for encoding in acceptedEncodings.elements where encoding != .none {
      if let name = encoding.nameIfSupported {
        headers.add(name, forKey: .acceptEncoding)
      }
    }

    for metadataPair in customMetadata {
      // Lowercase the field names for user-provided metadata.
      headers.add(name: metadataPair.key.lowercased(), value: metadataPair.value.encoded())
    }

    return headers
  }

  private mutating func clientSend(
    metadata: Metadata,
    configuration: GRPCStreamStateMachineConfiguration.ClientConfiguration
  ) throws(UnreachableTransition) -> OnSendMetadata {
    // Client sends metadata only when opening the stream.
    switch self.state {
    case .clientIdleServerIdle(let state):
      let outboundEncoding = configuration.outboundEncoding
      let compressor = Zlib.Method(encoding: outboundEncoding)
        .flatMap { Zlib.Compressor(method: $0) }
      self.state = .clientOpenServerIdle(
        .init(
          previousState: state,
          compressor: compressor,
          outboundCompression: outboundEncoding,
          framer: GRPCMessageFramer(),
          decompressor: nil,
          deframer: nil,
          headers: [:]
        )
      )

      let headers = self.makeClientHeaders(
        methodDescriptor: configuration.methodDescriptor,
        scheme: configuration.scheme,
        authority: configuration.authority,
        outboundEncoding: configuration.outboundEncoding,
        acceptedEncodings: configuration.acceptedEncodings,
        customMetadata: metadata
      )

      return .write(headers)

    case .clientOpenServerIdle, .clientOpenServerOpen, .clientOpenServerClosed:
      // This is unreachable by construction: higher level APIs should not make it possible
      // to send client metadata more than once.
      try self.unreachable("Client is already open: shouldn't be sending metadata.")

    case .clientClosedServerIdle, .clientClosedServerOpen, .clientClosedServerClosed:
      // This is unreachable by construction: the client is closed, meaning it has already sent
      // end stream, sending metadata now is a bug in a higher level abstraction.
      try self.unreachable("Client is closed: can't send metadata.")

    case .poisoned(let state):
      return .failPromise(state.rpcError)

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func clientSend(
    message: ByteBuffer,
    promise: EventLoopPromise<Void>?
  ) throws(UnreachableTransition) -> OnSendMessage {
    switch self.state {
    case .clientIdleServerIdle:
      // This is unreachable by construction: the client hasn't opened yet, higher level
      // APIs should enforce that metadata is sent first.
      try self.unreachable("Client not yet open.")

    case .clientOpenServerIdle(var state):
      self.state = ._modifying
      state.framer.append(message, promise: promise)
      self.state = .clientOpenServerIdle(state)
      return .nothing

    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      state.framer.append(message, promise: promise)
      self.state = .clientOpenServerOpen(state)
      return .nothing

    case .clientOpenServerClosed:
      // The server has closed, so it makes no sense to send the rest of the request. The promise
      // is succeeded in order to avoid throwing in client code where the RPC has already received
      // the final outcome from the server.
      return .succeedPromise

    case .clientClosedServerIdle, .clientClosedServerOpen, .clientClosedServerClosed:
      // This is unreachable by construction: higher level APIs must guarantee that
      // no messages are sent after half-closing.
      try self.unreachable("Client is closed, cannot send a message.")

    case .poisoned(let state):
      return .failPromise(state.rpcError)

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func clientCloseOutbound() throws(UnreachableTransition) {
    switch self.state {
    case .clientIdleServerIdle(let state):
      self.state = .clientClosedServerIdle(.init(previousState: state))
    case .clientOpenServerIdle(let state):
      self.state = .clientClosedServerIdle(.init(previousState: state))
    case .clientOpenServerOpen(let state):
      self.state = .clientClosedServerOpen(.init(previousState: state))
    case .clientOpenServerClosed(let state):
      self.state = .clientClosedServerClosed(.init(previousState: state))
    case .clientClosedServerIdle, .clientClosedServerOpen, .clientClosedServerClosed:
      ()  // Client is already closed - nothing to do.
    case .poisoned:
      ()  // No-op, already in an error state.
    case ._modifying:
      preconditionFailure()
    }
  }

  private enum ServerHeadersValidationResult {
    case valid
    case invalid(OnMetadataReceived)
    case skip
  }

  private mutating func clientValidateHeadersReceivedFromServer(
    _ metadata: HPACKHeaders
  ) -> ServerHeadersValidationResult {
    var httpStatus: String? {
      metadata.firstString(forKey: .status)
    }
    var grpcStatus: Status.Code? {
      metadata.firstString(forKey: .grpcStatus)
        .flatMap { Int($0) }
        .flatMap { Status.Code(rawValue: $0) }
    }
    guard httpStatus == "200" || grpcStatus != nil else {
      let httpStatusCode =
        httpStatus
        .flatMap { Int($0) }
        .map { HTTPResponseStatus(statusCode: $0) }

      guard let httpStatusCode else {
        return .invalid(
          .receivedStatusAndMetadata_clientOnly(
            status: .init(code: .unknown, message: "HTTP Status Code is missing."),
            metadata: Metadata(headers: metadata)
          )
        )
      }

      if (100 ... 199).contains(httpStatusCode.code) {
        // For 1xx status codes, the entire header should be skipped and a
        // subsequent header should be read.
        // See https://github.com/grpc/grpc/blob/7f664c69b2a636386fbf95c16bc78c559734ce0f/doc/http-grpc-status-mapping.md
        return .skip
      }

      // Forward the mapped status code.
      return .invalid(
        .receivedStatusAndMetadata_clientOnly(
          status: .init(
            code: Status.Code(httpStatusCode: httpStatusCode),
            message: "Unexpected non-200 HTTP Status Code (\(httpStatusCode))."
          ),
          metadata: Metadata(headers: metadata)
        )
      )
    }

    let contentTypeHeader = metadata.first(name: GRPCHTTP2Keys.contentType.rawValue)
    guard contentTypeHeader.flatMap(ContentType.init) != nil else {
      return .invalid(
        .receivedStatusAndMetadata_clientOnly(
          status: .init(
            code: .internalError,
            message: "Missing \(GRPCHTTP2Keys.contentType.rawValue) header"
          ),
          metadata: Metadata(headers: metadata)
        )
      )
    }

    return .valid
  }

  private enum ProcessInboundEncodingResult {
    case error(OnMetadataReceived)
    case success(CompressionAlgorithm)
  }

  private func processInboundEncoding(
    headers: HPACKHeaders,
    configuration: GRPCStreamStateMachineConfiguration.ClientConfiguration
  ) -> ProcessInboundEncodingResult {
    let inboundEncoding: CompressionAlgorithm
    if let serverEncoding = headers.first(name: GRPCHTTP2Keys.encoding.rawValue) {
      guard let parsedEncoding = CompressionAlgorithm(name: serverEncoding),
        configuration.acceptedEncodings.contains(parsedEncoding)
      else {
        return .error(
          .receivedStatusAndMetadata_clientOnly(
            status: .init(
              code: .internalError,
              message:
                "The server picked a compression algorithm ('\(serverEncoding)') the client does not know about."
            ),
            metadata: Metadata(headers: headers)
          )
        )
      }
      inboundEncoding = parsedEncoding
    } else {
      inboundEncoding = .none
    }
    return .success(inboundEncoding)
  }

  private func validateTrailers(
    _ trailers: HPACKHeaders
  ) throws(UnreachableTransition) -> OnMetadataReceived {
    let statusValue = trailers.firstString(forKey: .grpcStatus)
    let statusCode = statusValue.flatMap {
      Int($0)
    }.flatMap {
      Status.Code(rawValue: $0)
    }

    let status: Status
    if let code = statusCode {
      let messageFieldValue = trailers.firstString(forKey: .grpcStatusMessage, canonicalForm: false)
      let message = messageFieldValue.map { GRPCStatusMessageMarshaller.unmarshall($0) } ?? ""
      status = Status(code: code, message: message)
    } else {
      let message: String
      if let statusValue = statusValue {
        message = "Invalid 'grpc-status' in trailers (\(statusValue))"
      } else {
        message = "No 'grpc-status' value in trailers"
      }
      status = Status(code: .unknown, message: message)
    }

    var convertedMetadata = Metadata(headers: trailers)
    convertedMetadata.removeAllValues(forKey: GRPCHTTP2Keys.grpcStatus.rawValue)
    convertedMetadata.removeAllValues(forKey: GRPCHTTP2Keys.grpcStatusMessage.rawValue)

    return .receivedStatusAndMetadata_clientOnly(status: status, metadata: convertedMetadata)
  }

  private mutating func clientReceive(
    headers: HPACKHeaders,
    endStream: Bool,
    configuration: GRPCStreamStateMachineConfiguration.ClientConfiguration
  ) throws(UnreachableTransition) -> OnMetadataReceived {
    switch self.state {
    case .clientOpenServerIdle(let state):
      switch (self.clientValidateHeadersReceivedFromServer(headers), endStream) {
      case (.skip, _):
        // Headers should be ignored, so do nothing for now.
        return .doNothing

      case (.invalid(let action), _):
        // The received headers are invalid, so we can't do anything other than assume this server
        // is not behaving correctly. This is a protocol failure.
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        return action

      case (.valid, true):
        // This is a trailers-only response: close server.
        self.state = .clientOpenServerClosed(.init(previousState: state))
        return try self.validateTrailers(headers)

      case (.valid, false):
        switch self.processInboundEncoding(headers: headers, configuration: configuration) {
        case .error(let failure):
          self.state = .poisoned(.init(previousState: state, reason: .protocol))
          return failure

        case .success(let inboundEncoding):
          let decompressor = Zlib.Method(encoding: inboundEncoding)
            .flatMap { Zlib.Decompressor(method: $0) }

          self.state = .clientOpenServerOpen(
            .init(
              previousState: state,
              deframer: GRPCMessageDeframer(
                maxPayloadSize: state.maxPayloadSize,
                decompressor: decompressor
              ),
              decompressor: decompressor
            )
          )
          return .receivedMetadata(Metadata(headers: headers), nil)
        }
      }

    case .clientOpenServerOpen(let state):
      // This state is valid even if endStream is not set: server can send
      // trailing metadata without END_STREAM set, and follow it with an
      // empty message frame where it is set.
      // However, we must make sure that grpc-status is set, otherwise this
      // is an invalid state.
      if endStream {
        self.state = .clientOpenServerClosed(.init(previousState: state))
      }
      return try self.validateTrailers(headers)

    case .clientClosedServerIdle(let state):
      switch (self.clientValidateHeadersReceivedFromServer(headers), endStream) {
      case (.skip, _):
        // Headers should be ignored, so do nothing for now.
        return .doNothing

      case (.invalid(let action), _):
        // The received headers are invalid, so we can't do anything other than assume this server
        // is not behaving correctly. This is a protocol failure.
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        return action

      case (.valid, true):
        // This is a trailers-only response: close server.
        self.state = .clientClosedServerClosed(.init(previousState: state))
        return try self.validateTrailers(headers)

      case (.valid, false):
        switch self.processInboundEncoding(headers: headers, configuration: configuration) {
        case .error(let failure):
          self.state = .poisoned(.init(previousState: state, reason: .protocol))
          return failure
        case .success(let inboundEncoding):
          self.state = .clientClosedServerOpen(
            .init(
              previousState: state,
              decompressionAlgorithm: inboundEncoding
            )
          )
          return .receivedMetadata(Metadata(headers: headers), nil)
        }
      }

    case .clientClosedServerOpen(let state):
      // This state is valid even if endStream is not set: server can send
      // trailing metadata without END_STREAM set, and follow it with an
      // empty message frame where it is set.
      // However, we must make sure that grpc-status is set, otherwise this
      // is an invalid state.
      if endStream {
        self.state = .clientClosedServerClosed(.init(previousState: state))
      }
      return try self.validateTrailers(headers)

    case .clientOpenServerClosed(let state):
      // We've transitioned the server to closed: drop any other incoming headers.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .doNothing

    case .clientClosedServerClosed(let state):
      // We've transitioned the server to closed: drop any other incoming headers.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .doNothing

    case .clientIdleServerIdle(let state):
      // The client hasn't opened a stream yet; receiving server headers is an HTTP/2 protocol
      // violation that swift-nio-http2 should prevent. Treat defensively as a protocol error.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .receivedStatusAndMetadata_clientOnly(
        status: .init(
          code: .internalError,
          message: "Received headers from server before writing client headers."
        ),
        metadata: Metadata(headers: headers)
      )

    case .poisoned:
      // Already in an error state, ignore the headers.
      return .doNothing

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func clientReceive(
    buffer: ByteBuffer,
    endStream: Bool
  ) -> OnBufferReceivedAction {
    // This is a message received by the client, from the server.
    switch self.state {
    case .clientIdleServerIdle(let state):
      // The client hasn't opened a stream yet; receiving server data is an HTTP/2 protocol
      // violation that swift-nio-http2 should prevent. Treat defensively as a protocol error.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .doNothing

    case .clientOpenServerIdle(let state):
      // The server sent DATA before its initial HEADERS — an HTTP/2 protocol violation that
      // swift-nio-http2 should prevent. Treat defensively as a protocol error.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .endRPCAndForwardErrorStatus_clientOnly(
        Status(
          code: .internalError,
          message: "Server sent a DATA frame before sending initial metadata."
        )
      )

    case .clientClosedServerIdle(let state):
      // The server sent DATA before its initial HEADERS — an HTTP/2 protocol violation that
      // swift-nio-http2 should prevent. Treat defensively as a protocol error.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .endRPCAndForwardErrorStatus_clientOnly(
        Status(
          code: .internalError,
          message: "Server sent a DATA frame before sending initial metadata."
        )
      )

    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      if endStream {
        // This is invalid as per the protocol specification, because the server
        // can only close by sending trailers, not by setting EOS when sending
        // a message.
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        return .endRPCAndForwardErrorStatus_clientOnly(
          Status(
            code: .internalError,
            message: """
              Server sent EOS alongside a data frame, but server is only allowed \
              to close by sending status and trailers.
              """
          )
        )
      }

      state.deframer.append(buffer)

      do {
        try state.deframer.decode(into: &state.inboundMessageBuffer)
        self.state = .clientOpenServerOpen(state)
        return .readInbound
      } catch {
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        let status = Status(code: .internalError, message: "Failed to decode message")
        return .endRPCAndForwardErrorStatus_clientOnly(status)
      }

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      if endStream {
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        return .endRPCAndForwardErrorStatus_clientOnly(
          Status(
            code: .internalError,
            message: """
              Server sent EOS alongside a data frame, but server is only allowed \
              to close by sending status and trailers.
              """
          )
        )
      }

      // The client may have sent the end stream and thus it's closed,
      // but the server may still be responding.
      // The client must have a deframer set up, so force-unwrap is okay.
      do {
        state.deframer!.append(buffer)
        try state.deframer!.decode(into: &state.inboundMessageBuffer)
        self.state = .clientClosedServerOpen(state)
        return .readInbound
      } catch {
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        let status = Status(code: .internalError, message: "Failed to decode message \(error)")
        return .endRPCAndForwardErrorStatus_clientOnly(status)
      }

    case .clientOpenServerClosed(let state):
      // This shouldn't be possible: the server has closed by sending end-stream and
      // swift-nio-http2 should catch this. Nonetheless we treat it as a protocol violation and
      // drop the data.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .doNothing

    case .clientClosedServerClosed(let state):
      // This shouldn't be possible: both client and server have closed by sending end-stream and
      // swift-nio-http2 should catch this. Nonetheless we treat it as a protocol violation and
      // drop the data.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .doNothing

    case .poisoned:
      // Already in an error state, drop the buffer.
      return .doNothing

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func clientNextInboundMessage() -> OnNextInboundMessage {
    switch self.state {
    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      let message = state.inboundMessageBuffer.pop()
      self.state = .clientOpenServerOpen(state)
      return message.map { .receiveMessage($0) } ?? .awaitMoreMessages

    case .clientOpenServerClosed(var state):
      self.state = ._modifying
      let message = state.inboundMessageBuffer.pop()
      self.state = .clientOpenServerClosed(state)
      return message.map { .receiveMessage($0) } ?? .noMoreMessages

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      let message = state.inboundMessageBuffer.pop()
      self.state = .clientClosedServerOpen(state)
      return message.map { .receiveMessage($0) } ?? .awaitMoreMessages

    case .clientClosedServerClosed(var state):
      self.state = ._modifying
      let message = state.inboundMessageBuffer.pop()
      self.state = .clientClosedServerClosed(state)
      return message.map { .receiveMessage($0) } ?? .noMoreMessages

    case .clientIdleServerIdle,
      .clientOpenServerIdle,
      .clientClosedServerIdle:
      return .awaitMoreMessages

    case .poisoned:
      return .noMoreMessages

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func unreachable(
    _ message: String,
    line: UInt = #line,
    function: String = #function
  ) throws(UnreachableTransition) -> Never {
    let reason = GRPCStreamStateMachineState.Poisoned.Reason.unreachableTransition(
      state: self.state.name,
      function: function
    )

    switch self.state {
    case .clientIdleServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientOpenServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientOpenServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientOpenServerClosed(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientClosedServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientClosedServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .clientClosedServerClosed(let state):
      self.state = .poisoned(.init(previousState: state, reason: reason))
    case .poisoned:
      ()
    case ._modifying:
      preconditionFailure()
    }

    if !self.skipAssertions {
      assertionFailure(message, line: line)
    }

    throw UnreachableTransition(message)
  }

  private mutating func clientUnexpectedClose(
    reason: UnexpectedInboundCloseReason
  ) -> OnUnexpectedInboundClose {
    switch self.state {
    case .clientIdleServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return .forwardStatus_clientOnly(Status(RPCError(reason)))

    case .clientOpenServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return .forwardStatus_clientOnly(Status(RPCError(reason)))

    case .clientClosedServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return .forwardStatus_clientOnly(Status(RPCError(reason)))

    case .clientOpenServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return .forwardStatus_clientOnly(Status(RPCError(reason)))

    case .clientClosedServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return .forwardStatus_clientOnly(Status(RPCError(reason)))

    case .clientOpenServerClosed(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      // Already received end stream from the server.
      return .doNothing

    case .clientClosedServerClosed:
      // Already closed cleanly, ignore.
      return .doNothing

    case .poisoned:
      return .doNothing

    case ._modifying:
      preconditionFailure()
    }
  }
}

// - MARK: Server

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCStreamStateMachine {
  private func formResponseHeaders(
    in headers: inout HPACKHeaders,
    outboundEncoding encoding: CompressionAlgorithm?,
    configuration: GRPCStreamStateMachineConfiguration.ServerConfiguration,
    customMetadata: Metadata
  ) {
    headers.removeAll(keepingCapacity: true)

    // Response headers always contain :status (HTTP Status 200) and content-type.
    // They may also contain grpc-encoding, grpc-accept-encoding, and custom metadata.
    headers.reserveCapacity(4 + customMetadata.count)

    headers.add("200", forKey: .status)
    headers.add(ContentType.grpc.canonicalValue, forKey: .contentType)

    if let encoding, encoding != .none, let name = encoding.nameIfSupported {
      headers.add(name, forKey: .encoding)
    }

    for metadataPair in customMetadata {
      // Lowercase the field names for user-provided metadata.
      headers.add(name: metadataPair.key.lowercased(), value: metadataPair.value.encoded())
    }
  }

  private mutating func serverSend(
    metadata: Metadata,
    configuration: GRPCStreamStateMachineConfiguration.ServerConfiguration
  ) throws(UnreachableTransition) -> OnSendMetadata {
    // Server sends initial metadata
    switch self.state {
    case .clientOpenServerIdle(var state):
      self.state = ._modifying
      let outboundEncoding = state.outboundCompression
      self.formResponseHeaders(
        in: &state.headers,
        outboundEncoding: outboundEncoding,
        configuration: configuration,
        customMetadata: metadata
      )

      self.state = .clientOpenServerOpen(
        .init(
          previousState: state,
          // In the case of the server, it will already have a deframer set up,
          // because it already knows what encoding the client is using:
          // it's okay to force-unwrap.
          deframer: state.deframer!,
          decompressor: state.decompressor
        )
      )

      return .write(state.headers)

    case .clientClosedServerIdle(var state):
      self.state = ._modifying
      let outboundEncoding = state.outboundCompression
      self.formResponseHeaders(
        in: &state.headers,
        outboundEncoding: outboundEncoding,
        configuration: configuration,
        customMetadata: metadata
      )
      self.state = .clientClosedServerOpen(.init(previousState: state))
      return .write(state.headers)

    case .clientIdleServerIdle:
      // Unreachable by construction: higher level APIs ensure it's not possible for the server
      // to send metadata until it has received client metadata.
      try self.unreachable(
        "Client cannot be idle if server is sending initial metadata: it must have opened."
      )

    case .clientOpenServerClosed, .clientClosedServerClosed:
      // Unreachable by construction: higher level APIs ensure it's not possible for the server
      // to send initial metadata more than once.
      try self.unreachable("Server cannot send metadata if closed.")

    case .clientOpenServerOpen, .clientClosedServerOpen:
      // Unreachable by construction: higher level APIs ensure it's not possible for the server
      // to send initial metadata more than once.
      try self.unreachable("Server has already sent initial metadata.")

    case .poisoned(let state):
      return .failPromise(state.rpcError)

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func serverSend(
    message: ByteBuffer,
    promise: EventLoopPromise<Void>?
  ) throws(UnreachableTransition) -> OnSendMessage {
    switch self.state {
    case .clientIdleServerIdle, .clientOpenServerIdle, .clientClosedServerIdle:
      try self.unreachable(
        "Server must have sent initial metadata before sending a message."
      )

    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      state.framer.append(message, promise: promise)
      self.state = .clientOpenServerOpen(state)
      return .nothing

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      state.framer.append(message, promise: promise)
      self.state = .clientClosedServerOpen(state)
      return .nothing

    case .clientOpenServerClosed, .clientClosedServerClosed:
      // Unreachable by construction: high level APIs ensure that messages can't be sent
      // after the server has half closed.
      try self.unreachable("Server can't send a message if it's closed.")

    case .poisoned(let state):
      return .failPromise(state.rpcError)

    case ._modifying:
      preconditionFailure()
    }
  }

  enum OnServerSendStatus {
    case writeTrailers(HPACKHeaders)
    case dropAndFailPromise(RPCError)
  }

  private mutating func serverSend(
    status: Status,
    customMetadata: Metadata
  ) throws(UnreachableTransition) -> OnServerSendStatus {
    // Close the server.
    switch self.state {
    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      state.headers.formTrailers(status: status, metadata: customMetadata)
      self.state = .clientOpenServerClosed(.init(previousState: state))
      return .writeTrailers(state.headers)

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      state.headers.formTrailers(status: status, metadata: customMetadata)
      self.state = .clientClosedServerClosed(.init(previousState: state))
      return .writeTrailers(state.headers)

    case .clientOpenServerIdle(var state):
      self.state = ._modifying
      state.headers.formTrailersOnly(status: status, metadata: customMetadata)
      self.state = .clientOpenServerClosed(.init(previousState: state))
      return .writeTrailers(state.headers)

    case .clientClosedServerIdle(var state):
      self.state = ._modifying
      state.headers.formTrailersOnly(status: status, metadata: customMetadata)
      self.state = .clientClosedServerClosed(.init(previousState: state))
      return .writeTrailers(state.headers)

    case .clientIdleServerIdle:
      // Unreachable by construction: higher level APIs ensure that the server can't send a status
      // until it has received metadata from the client.
      try self.unreachable("Server can't send status if client is idle.")

    case .clientOpenServerClosed, .clientClosedServerClosed:
      return .dropAndFailPromise(
        RPCError(
          code: .internalError,
          message: "Can't write status, stream has already closed"
        )
      )

    case .poisoned(let state):
      return .dropAndFailPromise(state.rpcError)

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func serverReceive(
    headers: HPACKHeaders,
    endStream: Bool,
    configuration: GRPCStreamStateMachineConfiguration.ServerConfiguration
  ) -> OnMetadataReceived {
    func closeServer(
      from state: GRPCStreamStateMachineState.ClientIdleServerIdleState,
      endStream: Bool
    ) -> GRPCStreamStateMachineState {
      if endStream {
        return .clientClosedServerClosed(.init(previousState: state))
      } else {
        return .clientOpenServerClosed(.init(previousState: state))
      }
    }

    switch self.state {
    case .clientIdleServerIdle(let state):
      let contentType = headers.firstString(forKey: .contentType)
        .flatMap { ContentType(value: $0) }
      if contentType == nil {
        self.state = closeServer(from: state, endStream: endStream)

        // Respond with HTTP-level Unsupported Media Type status code.
        var trailers = HPACKHeaders()
        trailers.add("415", forKey: .status)
        return .rejectRPC_serverOnly(trailers: trailers)
      }

      guard let pathHeader = headers.firstString(forKey: .path) else {
        self.state = closeServer(from: state, endStream: endStream)
        return .rejectRPC_serverOnly(
          trailers: .trailersOnly(
            code: .invalidArgument,
            message: "No \(GRPCHTTP2Keys.path.rawValue) header has been set."
          )
        )
      }

      let scheme = headers.firstString(forKey: .scheme).flatMap { Scheme(rawValue: $0) }
      if scheme == nil {
        self.state = closeServer(from: state, endStream: endStream)
        return .rejectRPC_serverOnly(
          trailers: .trailersOnly(
            code: .invalidArgument,
            message: ":scheme header must be present and one of \"http\" or \"https\"."
          )
        )
      }

      guard let method = headers.firstString(forKey: .method), method == "POST" else {
        self.state = closeServer(from: state, endStream: endStream)
        return .rejectRPC_serverOnly(
          trailers: .trailersOnly(
            code: .invalidArgument,
            message: ":method header is expected to be present and have a value of \"POST\"."
          )
        )
      }

      // Firstly, find out if we support the client's chosen encoding, and reject
      // the RPC if we don't.
      let inboundEncoding: CompressionAlgorithm
      let encodingValues = headers.values(
        forHeader: GRPCHTTP2Keys.encoding.rawValue,
        canonicalForm: true
      )
      var encodingValuesIterator = encodingValues.makeIterator()
      if let rawEncoding = encodingValuesIterator.next() {
        guard encodingValuesIterator.next() == nil else {
          self.state = closeServer(from: state, endStream: endStream)
          return .rejectRPC_serverOnly(
            trailers: .trailersOnly(
              code: .internalError,
              message: "\(GRPCHTTP2Keys.encoding) must contain no more than one value."
            )
          )
        }

        guard let clientEncoding = CompressionAlgorithm(name: rawEncoding),
          configuration.acceptedEncodings.contains(clientEncoding)
        else {
          self.state = closeServer(from: state, endStream: endStream)
          var trailers = HPACKHeaders.trailersOnly(
            code: .unimplemented,
            message: """
              \(rawEncoding) compression is not supported; \
              supported algorithms are listed in grpc-accept-encoding
              """
          )

          for acceptedEncoding in configuration.acceptedEncodings.elements {
            if let name = acceptedEncoding.nameIfSupported {
              trailers.add(name: GRPCHTTP2Keys.acceptEncoding.rawValue, value: name)
            }
          }

          return .rejectRPC_serverOnly(trailers: trailers)
        }

        // Server supports client's encoding.
        inboundEncoding = clientEncoding
      } else {
        inboundEncoding = .none
      }

      // Secondly, find a compatible encoding the server can use to compress outbound messages,
      // based on the encodings the client has advertised.
      var outboundEncoding: CompressionAlgorithm = .none
      let clientAdvertisedEncodings = headers.values(
        forHeader: GRPCHTTP2Keys.acceptEncoding.rawValue,
        canonicalForm: true
      )
      // Find the preferred encoding and use it to compress responses.
      for clientAdvertisedEncoding in clientAdvertisedEncodings {
        if let algorithm = CompressionAlgorithm(name: clientAdvertisedEncoding),
          configuration.acceptedEncodings.contains(algorithm)
        {
          outboundEncoding = algorithm
          break
        }
      }

      if endStream {
        self.state = .clientClosedServerIdle(
          .init(
            previousState: state,
            compressionAlgorithm: outboundEncoding,
            headers: headers
          )
        )
      } else {
        let compressor = Zlib.Method(encoding: outboundEncoding)
          .flatMap { Zlib.Compressor(method: $0) }
        let decompressor = Zlib.Method(encoding: inboundEncoding)
          .flatMap { Zlib.Decompressor(method: $0) }

        self.state = .clientOpenServerIdle(
          .init(
            previousState: state,
            compressor: compressor,
            outboundCompression: outboundEncoding,
            framer: GRPCMessageFramer(),
            decompressor: decompressor,
            deframer: GRPCMessageDeframer(
              maxPayloadSize: state.maxPayloadSize,
              decompressor: decompressor
            ),
            headers: headers
          )
        )
      }

      return .receivedMetadata(Metadata(headers: headers), pathHeader)

    case .clientOpenServerIdle(let state):
      // Metadata has already been received, should only be sent once by clients.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .clientOpenServerOpen(let state):
      // Metadata has already been received, should only be sent once by clients.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .clientOpenServerClosed(let state):
      // Metadata has already been received, should only be sent once by clients.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .clientClosedServerIdle(let state):
      // The client already sent END_STREAM; receiving another HEADERS frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent. Treat defensively.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .clientClosedServerOpen(let state):
      // The client already sent END_STREAM; receiving another HEADERS frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent. Treat defensively.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .clientClosedServerClosed(let state):
      // The client already sent END_STREAM; receiving another HEADERS frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent. Treat defensively.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      return .protocolViolation_serverOnly

    case .poisoned:
      return .doNothing

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func serverReceive(
    buffer: ByteBuffer,
    endStream: Bool
  ) -> OnBufferReceivedAction {
    let action: OnBufferReceivedAction

    switch self.state {
    case .clientIdleServerIdle(let state):
      // No stream has been opened by the client; receiving DATA is an HTTP/2 protocol violation
      // that swift-nio-http2 should prevent. Treat defensively as a protocol error.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      action = .forwardErrorAndClose_serverOnly(
        RPCError(code: .internalError, message: "Received DATA frame before client sent HEADERS.")
      )

    case .clientOpenServerIdle(var state):
      self.state = ._modifying

      // Deframer must be present on the server side, as we know the decompression
      // algorithm from the moment the client opens.
      do {
        state.deframer!.append(buffer)
        try state.deframer!.decode(into: &state.inboundMessageBuffer)

        if endStream {
          self.state = .clientClosedServerIdle(.init(previousState: state))
        } else {
          self.state = .clientOpenServerIdle(state)
        }

        action = .readInbound
      } catch {
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        action = .forwardErrorAndClose_serverOnly(
          RPCError(code: .internalError, message: "Failed to decode message")
        )
      }

    case .clientOpenServerOpen(var state):
      self.state = ._modifying

      do {
        state.deframer.append(buffer)
        try state.deframer.decode(into: &state.inboundMessageBuffer)

        if endStream {
          self.state = .clientClosedServerOpen(.init(previousState: state))
        } else {
          self.state = .clientOpenServerOpen(state)
        }

        action = .readInbound
      } catch {
        self.state = .poisoned(.init(previousState: state, reason: .protocol))
        action = .forwardErrorAndClose_serverOnly(
          RPCError(code: .internalError, message: "Failed to decode message")
        )
      }

    case .clientOpenServerClosed(let state):
      // Client is not done sending request, but server has already closed.
      // Ignore the rest of the request: do nothing, unless endStream is set,
      // in which case close the client.
      if endStream {
        self.state = .clientClosedServerClosed(.init(previousState: state))
      }
      action = .doNothing

    case .clientClosedServerIdle(let state):
      // The client already sent END_STREAM; receiving another DATA frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      action = .forwardErrorAndClose_serverOnly(
        RPCError(code: .internalError, message: "Received DATA frame after client sent END_STREAM.")
      )

    case .clientClosedServerOpen(let state):
      // The client already sent END_STREAM; receiving another DATA frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      action = .forwardErrorAndClose_serverOnly(
        RPCError(code: .internalError, message: "Received DATA frame after client sent END_STREAM.")
      )

    case .clientClosedServerClosed(let state):
      // The client already sent END_STREAM; receiving another DATA frame from the client is an
      // HTTP/2 protocol violation that swift-nio-http2 should prevent.
      self.state = .poisoned(.init(previousState: state, reason: .protocol))
      // Do nothing (unlike above) as the server has already closed the stream.
      action = .doNothing

    case .poisoned:
      // Already in an error state, ignore the buffer.
      action = .doNothing

    case ._modifying:
      preconditionFailure()
    }

    return action
  }

  private mutating func serverNextInboundMessage() -> OnNextInboundMessage {
    switch self.state {
    case .clientOpenServerIdle(var state):
      self.state = ._modifying
      let request = state.inboundMessageBuffer.pop()
      self.state = .clientOpenServerIdle(state)
      return request.map { .receiveMessage($0) } ?? .awaitMoreMessages

    case .clientOpenServerOpen(var state):
      self.state = ._modifying
      let request = state.inboundMessageBuffer.pop()
      self.state = .clientOpenServerOpen(state)
      return request.map { .receiveMessage($0) } ?? .awaitMoreMessages

    case .clientClosedServerIdle(var state):
      self.state = ._modifying
      let request = state.inboundMessageBuffer.pop()
      self.state = .clientClosedServerIdle(state)
      return request.map { .receiveMessage($0) } ?? .noMoreMessages

    case .clientClosedServerOpen(var state):
      self.state = ._modifying
      let request = state.inboundMessageBuffer.pop()
      self.state = .clientClosedServerOpen(state)
      return request.map { .receiveMessage($0) } ?? .noMoreMessages

    case .clientOpenServerClosed, .clientClosedServerClosed:
      // Server has closed, no need to read.
      return .noMoreMessages

    case .clientIdleServerIdle:
      return .awaitMoreMessages

    case .poisoned:
      return .noMoreMessages

    case ._modifying:
      preconditionFailure()
    }
  }

  private mutating func serverUnexpectedClose(
    reason: UnexpectedInboundCloseReason
  ) -> OnUnexpectedInboundClose {
    switch self.state {
    case .clientIdleServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return OnUnexpectedInboundClose(serverCloseReason: reason)

    case .clientOpenServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return OnUnexpectedInboundClose(serverCloseReason: reason)

    case .clientOpenServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return OnUnexpectedInboundClose(serverCloseReason: reason)

    case .clientOpenServerClosed(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      // The server has already sent its final status; the RPC is complete from the server's
      // perspective. The unexpected close does not need to be surfaced to the application.
      return .doNothing

    case .clientClosedServerIdle(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return OnUnexpectedInboundClose(serverCloseReason: reason)

    case .clientClosedServerOpen(let state):
      self.state = .poisoned(.init(previousState: state, reason: .unexpectedClose))
      return OnUnexpectedInboundClose(serverCloseReason: reason)

    case .clientClosedServerClosed:
      // Already closed cleanly.
      return .doNothing

    case .poisoned:
      return .doNothing

    case ._modifying:
      preconditionFailure()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension MethodDescriptor {
  init?(path: String) {
    let utf8 = path.utf8
    var i = utf8.startIndex
    guard i < utf8.endIndex, utf8[i] == UInt8(ascii: "/") else { return nil }
    utf8.formIndex(after: &i)
    let serviceStart = i

    // Find the index of the "/" separating the service and method names.
    guard let slashIndex = utf8[serviceStart...].firstIndex(of: UInt8(ascii: "/")) else {
      return nil
    }

    let service = String(utf8[serviceStart ..< slashIndex])!
    let methodStart = utf8.index(after: slashIndex)
    let method = String(utf8[methodStart...])!

    self.init(service: ServiceDescriptor(fullyQualifiedService: service), method: method)
  }
}

internal enum GRPCHTTP2Keys: String {
  case authority = ":authority"
  case path = ":path"
  case contentType = "content-type"
  case encoding = "grpc-encoding"
  case acceptEncoding = "grpc-accept-encoding"
  case scheme = ":scheme"
  case method = ":method"
  case te = "te"
  case status = ":status"
  case grpcStatus = "grpc-status"
  case grpcStatusMessage = "grpc-message"
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HPACKHeaders {
  func firstString(forKey key: GRPCHTTP2Keys, canonicalForm: Bool = true) -> String? {
    self.values(forHeader: key.rawValue, canonicalForm: canonicalForm).first(where: { _ in true })
      .map {
        String($0)
      }
  }

  fileprivate mutating func add(_ value: String, forKey key: GRPCHTTP2Keys) {
    self.add(name: key.rawValue, value: value)
  }

  fileprivate static func trailersOnly(code: Status.Code, message: String) -> Self {
    var trailers = HPACKHeaders()
    HPACKHeaders.formTrailers(
      &trailers,
      isTrailersOnly: true,
      status: Status(code: code, message: message),
      metadata: [:]
    )
    return trailers
  }

  fileprivate mutating func formTrailersOnly(status: Status, metadata: Metadata = [:]) {
    Self.formTrailers(&self, isTrailersOnly: true, status: status, metadata: metadata)
  }

  fileprivate mutating func formTrailers(status: Status, metadata: Metadata = [:]) {
    Self.formTrailers(&self, isTrailersOnly: false, status: status, metadata: metadata)
  }

  private static func formTrailers(
    _ trailers: inout HPACKHeaders,
    isTrailersOnly: Bool,
    status: Status,
    metadata: Metadata
  ) {
    trailers.removeAll(keepingCapacity: true)

    if isTrailersOnly {
      trailers.reserveCapacity(4 + metadata.count)
      trailers.add("200", forKey: .status)
      trailers.add(ContentType.grpc.canonicalValue, forKey: .contentType)
    } else {
      trailers.reserveCapacity(2 + metadata.count)
    }

    trailers.add(String(status.code.rawValue), forKey: .grpcStatus)
    if !status.message.isEmpty, let encoded = GRPCStatusMessageMarshaller.marshall(status.message) {
      trailers.add(encoded, forKey: .grpcStatusMessage)
    }

    for (key, value) in metadata {
      // Lowercase the field names for user-provided metadata.
      trailers.add(name: key.lowercased(), value: value.encoded())
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension Zlib.Method {
  init?(encoding: CompressionAlgorithm) {
    switch encoding {
    case .none:
      return nil
    case .deflate:
      self = .deflate
    case .gzip:
      self = .gzip
    default:
      return nil
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension Metadata {
  init(headers: HPACKHeaders) {
    var metadata = Metadata()
    metadata.reserveCapacity(headers.count)
    for header in headers {
      if header.name.hasSuffix("-bin") {
        do {
          let decodedBinary = try Base64.decode(string: header.value)
          metadata.addBinary(decodedBinary, forKey: header.name)
        } catch {
          metadata.addString(header.value, forKey: header.name)
        }
      } else {
        metadata.addString(header.value, forKey: header.name)
      }
    }
    self = metadata
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension Status.Code {
  // See https://github.com/grpc/grpc/blob/7f664c69b2a636386fbf95c16bc78c559734ce0f/doc/http-grpc-status-mapping.md
  init(httpStatusCode: HTTPResponseStatus) {
    switch httpStatusCode {
    case .badRequest:
      self = .internalError
    case .unauthorized:
      self = .unauthenticated
    case .forbidden:
      self = .permissionDenied
    case .notFound:
      self = .unimplemented
    case .tooManyRequests, .badGateway, .serviceUnavailable, .gatewayTimeout:
      self = .unavailable
    default:
      self = .unknown
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension MethodDescriptor {
  var path: String {
    return "/\(self.service)/\(self.method)"
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension RPCError {
  fileprivate init(_ reason: GRPCStreamStateMachine.UnexpectedInboundCloseReason) {
    switch reason {
    case .streamReset(let errorCode):
      self = RPCError(
        code: .unavailable,
        message:
          "Stream unexpectedly closed: received RST_STREAM frame (\(errorCode.shortDescription))."
      )
    case .channelInactive:
      self = RPCError(code: .unavailable, message: "Stream unexpectedly closed.")
    case .errorThrown:
      self = RPCError(code: .unavailable, message: "Stream unexpectedly closed with error.")
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension Status {
  fileprivate init(_ error: RPCError) {
    self = Status(code: Status.Code(error.code), message: error.message)
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension RPCError {
  init(_ invalidState: GRPCStreamStateMachine.UnreachableTransition) {
    self = RPCError(code: .internalError, message: "Invalid state", cause: invalidState)
  }
}

extension HTTP2ErrorCode {
  var shortDescription: String {
    let prefix = "0x" + String(self.networkCode, radix: 16) + ": "
    let suffix: String

    switch self {
    case .noError:
      suffix = "no error"
    case .protocolError:
      suffix = "protocol error"
    case .internalError:
      suffix = "internal error"
    case .flowControlError:
      suffix = "flow control error"
    case .settingsTimeout:
      suffix = "settings Timeout"
    case .streamClosed:
      suffix = "stream closed"
    case .frameSizeError:
      suffix = "frame size error"
    case .refusedStream:
      suffix = "refused stream"
    case .cancel:
      suffix = "cancel"
    case .compressionError:
      suffix = "compression error"
    case .connectError:
      suffix = "connect error"
    case .enhanceYourCalm:
      suffix = "enhance your calm"
    case .inadequateSecurity:
      suffix = "inadequate security"
    case .http11Required:
      suffix = "HTTP/1.1 required"
    default:
      suffix = "unknown error"
    }
    return prefix + suffix
  }
}
