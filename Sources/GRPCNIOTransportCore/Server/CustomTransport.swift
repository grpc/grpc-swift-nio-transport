/*
 * Copyright 2024-2026, gRPC Authors All rights reserved.
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

public import GRPCCore
public import NIOCore
package import NIOExtras
private import NIOHTTP2
private import Synchronization

@available(gRPCSwiftNIOTransport 2.5, *)
extension HTTP2ServerTransport {
  /// A NIO-based server transport that handles HTTP/2 connections using a pluggable
  /// ``HTTP2ServerTransport/ListenerFactory``.
  ///
  /// This transport provides the core functionality for accepting HTTP/2 connections and
  /// dispatching RPC streams. It delegates the creation of the listening channel to a
  /// ``HTTP2ServerTransport/ListenerFactory`` implementation, allowing custom connection
  /// acceptance mechanisms (such as XPC) beyond the standard bind-accept pattern.
  ///
  /// To use this transport with a custom listener factory:
  /// 1. Implement ``HTTP2ServerTransport/ListenerFactory`` to create your listening channel.
  /// 2. Create an instance of this transport with your factory.
  /// 3. Pass the transport to a `GRPCServer`.
  ///
  /// This type does not conform to ``ListeningServerTransport``. If your transport has a
  /// listening address, you can conform your wrapper type to ``ListeningServerTransport``.
  ///
  /// - SeeAlso: ``HTTP2ServerTransport/ListenerFactory``.
  @available(gRPCSwiftNIOTransport 2.5, *)
  public final class Custom<
    ListenerFactory: HTTP2ServerTransport.ListenerFactory
  >: ServerTransport {
    public typealias Bytes = GRPCNIOTransportBytes

    /// Configuration for the custom HTTP/2 server transport.
    ///
    /// This groups the gRPC-level configuration that the transport uses to configure each accepted connection's HTTP/2 pipeline.
    public struct Config: Sendable {
      /// Compression configuration.
      public var compression: HTTP2ServerTransport.Config.Compression

      /// Connection configuration.
      public var connection: HTTP2ServerTransport.Config.Connection

      /// HTTP/2 configuration.
      public var http2: HTTP2ServerTransport.Config.HTTP2

      /// RPC configuration.
      public var rpc: HTTP2ServerTransport.Config.RPC

      /// Channel callbacks for debugging.
      public var channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks

      /// Creates a new configuration.
      ///
      /// - Parameters:
      ///   - compression: Compression configuration.
      ///   - connection: Connection configuration.
      ///   - http2: HTTP/2 configuration.
      ///   - rpc: RPC configuration.
      ///   - channelDebuggingCallbacks: Channel callbacks for debugging.
      public init(
        compression: HTTP2ServerTransport.Config.Compression,
        connection: HTTP2ServerTransport.Config.Connection,
        http2: HTTP2ServerTransport.Config.HTTP2,
        rpc: HTTP2ServerTransport.Config.RPC,
        channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
      ) {
        self.compression = compression
        self.connection = connection
        self.http2 = http2
        self.rpc = rpc
        self.channelDebuggingCallbacks = channelDebuggingCallbacks
      }

      /// Default values.
      ///
      /// - SeeAlso: ``HTTP2ServerTransport/Config/Compression/defaults``
      /// - SeeAlso: ``HTTP2ServerTransport/Config/Connection/defaults``
      /// - SeeAlso: ``HTTP2ServerTransport/Config/HTTP2/defaults``
      /// - SeeAlso: ``HTTP2ServerTransport/Config/RPC/defaults``
      /// - SeeAlso: ``HTTP2ServerTransport/Config/ChannelDebuggingCallbacks/defaults``
      public static var defaults: Self {
        Self(
          compression: .defaults,
          connection: .defaults,
          http2: .defaults,
          rpc: .defaults,
          channelDebuggingCallbacks: .defaults
        )
      }
    }

    private let listeningAddressState: Mutex<State>
    private let serverQuiescingHelper: ServerQuiescingHelper
    private let factory: ListenerFactory
    private let config: Config
    private let transportSpecificContext:
      (
        @Sendable (any Channel) async -> any ServerContext.TransportSpecific
      )?

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
        userProvidedAddress: SocketAddress?
      ) -> OnBound {
        switch self {
        case .idle(let listeningAddressPromise):
          if let address {
            self = .listening(listeningAddressPromise.futureResult)
            return .succeedPromise(listeningAddressPromise, address: SocketAddress(address))
          } else if let userProvidedAddress, userProvidedAddress.virtualSocket != nil {
            self = .listening(listeningAddressPromise.futureResult)
            return .succeedPromise(listeningAddressPromise, address: userProvidedAddress)
          } else {
            // In some cases (such as starting the server from an fd, it might not be possible to get
            // a socket address).
            let unavailableAddress = RuntimeError(
              code: .transportError,
              message:
                "Listener address isn't available. It may not correspond to a socket address."
            )
            self = .closedOrInvalidAddress(unavailableAddress)
            return .failPromise(listeningAddressPromise, error: unavailableAddress)
          }

        case .listening, .closedOrInvalidAddress:
          fatalError(
            "Invalid state: addressBound should only be called once and when in idle state"
          )
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
    /// invalid address, or if the listener doesn't have a corresponding socket address (e.g. when
    /// started from a file descriptor).
    public var listeningAddress: SocketAddress {
      get async throws {
        try await self.listeningAddressState
          .withLock { try $0.listeningAddressFuture }
          .get()
      }
    }

    /// Creates a new NIO-based HTTP/2 server transport.
    ///
    /// - Parameters:
    ///   - listenerFactory: The factory responsible for creating the listening channel.
    ///   - eventLoopGroup: The `EventLoopGroup` used for creating promises and event loops.
    ///   - config: The configuration for accepted connection channels. Defaults to ``Config/defaults``.
    public convenience init(
      listenerFactory: ListenerFactory,
      eventLoopGroup: any EventLoopGroup,
      config: Config = .defaults
    ) {
      self.init(
        eventLoopGroup: eventLoopGroup,
        quiescingHelper: ServerQuiescingHelper(group: eventLoopGroup),
        config: config,
        listenerFactory: listenerFactory
      )
    }

    package init(
      eventLoopGroup: any EventLoopGroup,
      quiescingHelper: ServerQuiescingHelper,
      config: Config,
      listenerFactory: ListenerFactory,
      transportSpecificContext: (
        @Sendable (any Channel) async -> any ServerContext.TransportSpecific
      )? = nil
    ) {
      let eventLoop = eventLoopGroup.any()
      self.listeningAddressState = Mutex(.idle(eventLoop.makePromise()))

      self.factory = listenerFactory
      self.serverQuiescingHelper = quiescingHelper
      self.config = config
      self.transportSpecificContext = transportSpecificContext
    }

    deinit {
      // Fail the promise if this transport is deallocated without ever being started.
      self.listeningAddressState.withLock { state in
        switch state.close() {
        case .failPromise(let promise, let error):
          promise.fail(error)
        case .doNothing:
          ()
        }
      }
    }

    public func listen(
      streamHandler:
        @escaping @Sendable (
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

      let listenerConfigurator = HTTP2ServerTransport.ListenerConfigurator { channel in
        let configured = channel.eventLoop.makeCompletedFuture {
          let quiescingHandler = self.serverQuiescingHelper.makeServerChannelHandler(
            channel: channel
          )
          try channel.pipeline.syncOperations.addHandler(quiescingHandler)
        }
        return configured.runInitializerIfSet(
          self.config.channelDebuggingCallbacks.onBindTCPListener,
          on: channel
        )
      }

      let connectionConfigurator = HTTP2ServerTransport.ConnectionConfigurator { channel, tls in
        let configured = channel.eventLoop.makeCompletedFuture {
          let (connection, mux) = try channel.pipeline.syncOperations.configureGRPCServerPipeline(
            channel: channel,
            compressionConfig: self.config.compression,
            connectionConfig: self.config.connection,
            http2Config: self.config.http2,
            rpcConfig: self.config.rpc,
            debugConfig: self.config.channelDebuggingCallbacks,
            requireALPN: tls.requireALPN,
            scheme: tls.usesTLS ? .https : .http
          )
          return ConnectionConfigurator.ConnectionChannel(
            connection: connection,
            multiplexer: mux
          )
        }
        return configured.runInitializerIfSet(
          self.config.channelDebuggingCallbacks.onAcceptTCPConnection,
          on: channel
        )
      }

      let serverChannel = try await self.factory.makeListeningChannel(
        listenerConfigurator: listenerConfigurator,
        connectionConfigurator: connectionConfigurator
      )

      let action = self.listeningAddressState.withLock {
        $0.addressBound(
          serverChannel.channel.localAddress,
          userProvidedAddress: self.factory.listeningAddress
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
          for try await configuredConnection in inbound {
            group.addTask {
              try await self.handleConnection(
                configuredConnection.connection,
                multiplexer: configuredConnection.multiplexer,
                streamHandler: streamHandler
              )
            }
          }
        }
      }
    }

    private func handleConnection(
      _ connection: NIOAsyncChannel<HTTP2Frame, HTTP2Frame>,
      multiplexer: ChannelPipeline.SynchronousOperations.HTTP2StreamMultiplexer,
      streamHandler:
        @escaping @Sendable (
          _ stream: RPCStream<Inbound, Outbound>,
          _ context: ServerContext
        ) async -> Void
    ) async throws {
      // In NIOTS the local/remote address is set just before channel becomes fires, so wait until
      // that has happened (if it hasn't already).
      if !connection.channel.isActive {
        try? await connection.channel.waitUntilActive().get()
      }

      let remotePeer = connection.channel.remoteAddressInfo
      let localPeer = connection.channel.localAddressInfo

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
                  connection,
                  handler: streamHandler,
                  descriptor: descriptor,
                  remotePeer: remotePeer,
                  localPeer: localPeer
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
      _ stream: NIOAsyncChannel<RPCRequestPart<Bytes>, RPCResponsePart<Bytes>>,
      _ connection: NIOAsyncChannel<HTTP2Frame, HTTP2Frame>,
      handler streamHandler:
        @escaping @Sendable (
          _ stream: RPCStream<Inbound, Outbound>,
          _ context: ServerContext
        ) async -> Void,
      descriptor: EventLoopFuture<MethodDescriptor>,
      remotePeer: String,
      localPeer: String
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

          var context = ServerContext(
            descriptor: descriptor,
            remotePeer: remotePeer,
            localPeer: localPeer,
            cancellation: handle
          )
          if let transportSpecificContext = self.transportSpecificContext {
            context.transportSpecific = await transportSpecificContext(connection.channel)
          }
          await streamHandler(rpcStream, context)
        }

        // Wait for the stream to close (i.e. when the final status has been written or an error
        // occurs.) This is done to avoid closing too early as 'executeThenClose' may forcefully
        // close the stream and drop buffered writes.
        //
        // If the task is cancelled then end stream might not have been written so the close future
        // won't complete yet. If the task has been cancelled then don't block here: the stream
        // will be closed by 'executeThenClose'.
        if !Task.isCancelled {
          try await stream.channel.closeFuture.get()
        }
      }
    }

    public func beginGracefulShutdown() {
      self.serverQuiescingHelper.initiateShutdown(promise: nil)
    }
  }

}
