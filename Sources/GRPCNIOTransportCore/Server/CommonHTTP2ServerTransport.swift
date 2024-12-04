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
package import NIOExtras
private import NIOHTTP2
private import Synchronization

/// Provides the common functionality for a `NIO`-based server transport.
///
/// - SeeAlso: ``HTTP2ListenerFactory``.
package final class CommonHTTP2ServerTransport<
  ListenerFactory: HTTP2ListenerFactory
>: ServerTransport, ListeningServerTransport {
  private let eventLoopGroup: any EventLoopGroup
  private let address: SocketAddress
  private let listeningAddressState: Mutex<State>
  private let serverQuiescingHelper: ServerQuiescingHelper
  private let factory: ListenerFactory

  private enum State {
    case idle(EventLoopPromise<SocketAddress>)
    case listening(EventLoopFuture<SocketAddress>)
    case closedOrInvalidAddress(RuntimeError)

    var listeningAddressFuture: EventLoopFuture<SocketAddress> {
      get throws {
        switch self {
        case .idle(let eventLoopPromise):
          return eventLoopPromise.futureResult
        case .listening(let eventLoopFuture):
          return eventLoopFuture
        case .closedOrInvalidAddress(let runtimeError):
          throw runtimeError
        }
      }
    }

    enum OnBound {
      case succeedPromise(_ promise: EventLoopPromise<SocketAddress>, address: SocketAddress)
      case failPromise(_ promise: EventLoopPromise<SocketAddress>, error: RuntimeError)
    }

    mutating func addressBound(
      _ address: NIOCore.SocketAddress?,
      userProvidedAddress: SocketAddress
    ) -> OnBound {
      switch self {
      case .idle(let listeningAddressPromise):
        if let address {
          self = .listening(listeningAddressPromise.futureResult)
          return .succeedPromise(listeningAddressPromise, address: SocketAddress(address))
        } else if userProvidedAddress.virtualSocket != nil {
          self = .listening(listeningAddressPromise.futureResult)
          return .succeedPromise(listeningAddressPromise, address: userProvidedAddress)
        } else {
          assertionFailure("Unknown address type")
          let invalidAddressError = RuntimeError(
            code: .transportError,
            message: "Unknown address type returned by transport."
          )
          self = .closedOrInvalidAddress(invalidAddressError)
          return .failPromise(listeningAddressPromise, error: invalidAddressError)
        }

      case .listening, .closedOrInvalidAddress:
        fatalError("Invalid state: addressBound should only be called once and when in idle state")
      }
    }

    enum OnClose {
      case failPromise(EventLoopPromise<SocketAddress>, error: RuntimeError)
      case doNothing
    }

    mutating func close() -> OnClose {
      let serverStoppedError = RuntimeError(
        code: .serverIsStopped,
        message: """
          There is no listening address bound for this server: there may have been \
          an error which caused the transport to close, or it may have shut down.
          """
      )

      switch self {
      case .idle(let listeningAddressPromise):
        self = .closedOrInvalidAddress(serverStoppedError)
        return .failPromise(listeningAddressPromise, error: serverStoppedError)

      case .listening:
        self = .closedOrInvalidAddress(serverStoppedError)
        return .doNothing

      case .closedOrInvalidAddress:
        return .doNothing
      }
    }
  }

  /// The listening address for this server transport.
  ///
  /// It is an `async` property because it will only return once the address has been successfully bound.
  ///
  /// - Throws: A runtime error will be thrown if the address could not be bound or is not bound any
  /// longer, because the transport isn't listening anymore. It can also throw if the transport returned an
  /// invalid address.
  package var listeningAddress: SocketAddress {
    get async throws {
      try await self.listeningAddressState
        .withLock { try $0.listeningAddressFuture }
        .get()
    }
  }

  package init(
    address: SocketAddress,
    eventLoopGroup: any EventLoopGroup,
    quiescingHelper: ServerQuiescingHelper,
    listenerFactory: ListenerFactory
  ) {
    self.eventLoopGroup = eventLoopGroup
    self.address = address

    let eventLoop = eventLoopGroup.any()
    self.listeningAddressState = Mutex(.idle(eventLoop.makePromise()))

    self.factory = listenerFactory
    self.serverQuiescingHelper = quiescingHelper
  }

  package func listen(
    streamHandler: @escaping @Sendable (
      _ stream: RPCStream<Inbound, Outbound>,
      _ context: ServerContext
    ) async -> Void
  ) async throws {
    defer {
      switch self.listeningAddressState.withLock({ $0.close() }) {
      case .failPromise(let promise, let error):
        promise.fail(error)
      case .doNothing:
        ()
      }
    }

    let serverChannel = try await self.factory.makeListeningChannel(
      eventLoopGroup: self.eventLoopGroup,
      address: self.address,
      serverQuiescingHelper: self.serverQuiescingHelper
    )

    let action = self.listeningAddressState.withLock {
      $0.addressBound(
        serverChannel.channel.localAddress,
        userProvidedAddress: self.address
      )
    }
    switch action {
    case .succeedPromise(let promise, let address):
      promise.succeed(address)
    case .failPromise(let promise, let error):
      promise.fail(error)
    }

    try await serverChannel.executeThenClose { inbound in
      try await withThrowingDiscardingTaskGroup { group in
        for try await (connectionChannel, streamMultiplexer) in inbound {
          group.addTask {
            try await self.handleConnection(
              connectionChannel,
              multiplexer: streamMultiplexer,
              streamHandler: streamHandler
            )
          }
        }
      }
    }
  }

  private func peerInfo(channel: any Channel) -> String {
    guard let remote = channel.remoteAddress else {
      return "<unknown>"
    }

    switch remote {
    case .v4(let address):
      // '!' is safe, v4 always has a port.
      return "ipv4:\(address.host):\(remote.port!)"

    case .v6(let address):
      // '!' is safe, v6 always has a port.
      return "ipv6:[\(address.host)]:\(remote.port!)"

    case .unixDomainSocket:
      // The pathname will be on the local address.
      guard let local = channel.localAddress else {
        // UDS but no local address; this shouldn't ever happen but at least note the transport
        // as being UDS.
        return "unix:<unknown>"
      }

      switch local {
      case .unixDomainSocket:
        // '!' is safe, UDS always has a path.
        return "unix:\(local.pathname!)"

      case .v4, .v6:
        // Remote address is UDS but local isn't. This shouldn't ever happen.
        return "unix:<unknown>"
      }
    }
  }

  private func handleConnection(
    _ connection: NIOAsyncChannel<HTTP2Frame, HTTP2Frame>,
    multiplexer: ChannelPipeline.SynchronousOperations.HTTP2StreamMultiplexer,
    streamHandler: @escaping @Sendable (
      _ stream: RPCStream<Inbound, Outbound>,
      _ context: ServerContext
    ) async -> Void
  ) async throws {
    let peer = self.peerInfo(channel: connection.channel)
    try await connection.executeThenClose { inbound, _ in
      await withDiscardingTaskGroup { group in
        group.addTask {
          do {
            for try await _ in inbound {}
          } catch {
            // We don't want to close the channel if one connection throws.
            return
          }
        }

        do {
          for try await (stream, descriptor) in multiplexer.inbound {
            group.addTask {
              await self.handleStream(
                stream,
                handler: streamHandler,
                descriptor: descriptor,
                peer: peer
              )
            }
          }
        } catch {
          return
        }
      }
    }
  }

  private func handleStream(
    _ stream: NIOAsyncChannel<RPCRequestPart, RPCResponsePart>,
    handler streamHandler: @escaping @Sendable (
      _ stream: RPCStream<Inbound, Outbound>,
      _ context: ServerContext
    ) async -> Void,
    descriptor: EventLoopFuture<MethodDescriptor>,
    peer: String
  ) async {
    // It's okay to ignore these errors:
    // - If we get an error because the http2Stream failed to close, then there's nothing we can do
    // - If we get an error because the inner closure threw, then the only possible scenario in which
    // that could happen is if methodDescriptor.get() throws - in which case, it means we never got
    // the RPC metadata, which means we can't do anything either and it's okay to just close the stream.
    try? await stream.executeThenClose { inbound, outbound in
      guard let descriptor = try? await descriptor.get() else {
        return
      }

      await withServerContextRPCCancellationHandle { handle in
        stream.channel.eventLoop.execute {
          // Sync is safe: this is on the right event loop.
          let sync = stream.channel.pipeline.syncOperations

          do {
            let handler = try sync.handler(type: GRPCServerStreamHandler.self)
            handler.setCancellationHandle(handle)
          } catch {
            // Looking up the handler can fail if the channel is already closed, in which case
            // don't execute the RPC, just return early.
            return
          }
        }

        let rpcStream = RPCStream(
          descriptor: descriptor,
          inbound: RPCAsyncSequence(wrapping: inbound),
          outbound: RPCWriter.Closable(
            wrapping: ServerConnection.Stream.Outbound(
              responseWriter: outbound,
              http2Stream: stream
            )
          )
        )

        let context = ServerContext(descriptor: descriptor, peer: peer, cancellation: handle)
        await streamHandler(rpcStream, context)
      }
    }
  }

  package func beginGracefulShutdown() {
    self.serverQuiescingHelper.initiateShutdown(promise: nil)
  }
}
