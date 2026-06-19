/*
 * Copyright 2025, gRPC Authors All rights reserved.
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
internal import NIOHTTP2
private import Synchronization

/// A client transport which wraps an existing SwiftNIO `Channel`.
///
/// You can use this if you already have a connected `Channel` that you'd like to use as a gRPC
/// client connection. This is helpful if, for example, you wish to tunnel gRPC inside another
/// protocol.
///
/// ## Limitations
///
/// This transport offers fewer features than its regular NIO based counterparts:
///
/// - **No reconnects.** Once the underlying `Channel` closes, the transport is done. Subsequent
///   RPCs fail with `unavailable`.
/// - **No load balancing or connection pooling.** It's a single `Channel`.
///   `ServiceConfig.loadBalancingConfig` is ignored. Retry throttling, if configured, still
///   applies.
/// - **No transparent TLS.** Wire TLS into your own pipeline before calling `configure`; the
///   transport doesn't set it up for you.
/// - **Streams queue until `SETTINGS`.** RPCs initiated before the server's first `SETTINGS`
///   frame is received are queued; if the connection fails before that, they fail with
///   `unavailable`.
///
/// ## Constructing a transport
///
/// Use ``wrapping(config:serviceConfig:makeChannel:)`` to build a transport. The factory hands you
/// a `configure` closure to call from inside your bootstrap's `channelInitializer`, alongside any
/// pre-gRPC handlers you need (TLS, any tunnelling handlers, etc.).
///
/// If you already hold an active `Channel` (for example after completing a tunnel handshake) you
/// can call `configure(channel)` directly inside `makeChannel`. In that case it is your
/// responsibility to ensure that no inbound bytes have flowed past the end of your pipeline
/// before `configure` runs — for instance by keeping your tunnel handler installed (and not
/// firing inbound bytes) until `configure` resolves.
///
/// ## Lifecycle
///
/// On success the transport takes ownership of the channel and is responsible for closing it. If
/// `makeChannel` throws, ownership stays with the caller. When the channel closes, in-flight RPCs
/// see the failure on their inbound stream and any RPCs still queued waiting for `SETTINGS` are
/// resumed with `unavailable`.
@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport {
  @available(gRPCSwiftNIOTransport 2.0, *)
  public final class WrappedChannel: ClientTransport {
    public typealias Bytes = GRPCNIOTransportBytes

    private let channel: any Channel
    private let serviceConfig: ServiceConfig
    private let methodConfig: MethodConfigs
    private let config: Config
    private let state: Mutex<State>
    private let preConfigured: Configured?

    public let retryThrottle: RetryThrottle?

    fileprivate struct Configured {
      var connection: NIOAsyncChannel<ClientConnectionEvent, Void>
      var multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
    }

    /// The default max request message size in bytes, 4 MiB.
    private static var defaultMaxRequestMessageSizeBytes: Int {
      4 * 1024 * 1024
    }

    /// Create a new wrapping client transport from an already connected NIO `Channel`.
    ///
    /// - Parameters:
    ///   - channel: The channel to wrap. The transport takes ownership of the lifetime of the channel
    ///       from this point onwards and is responsible for closing it when the transport is
    ///       finished.
    ///   - config: Configuration for the transport.
    ///   - serviceConfig: Service config controlling how the transport should handle individual
    ///       methods and throttle retries. Note that load-balancing policies are ignored by this
    ///       transport.
    @available(
      *,
      deprecated,
      message: """
        Use 'HTTP2ClientTransport.WrappedChannel.wrapping(config:serviceConfig:makeChannel:)' so the \
        gRPC pipeline is configured before the channel becomes active. The pre-existing init is \
        best-effort and may drop early server frames such as SETTINGS.
        """
    )
    public convenience init(
      takingOwnershipOf channel: consuming any Channel,
      config: Config = .defaults,
      serviceConfig: ServiceConfig = ServiceConfig()
    ) {
      self.init(
        takingOwnershipOf: channel,
        preConfigured: nil,
        config: config,
        serviceConfig: serviceConfig
      )
    }

    fileprivate init(
      takingOwnershipOf channel: consuming any Channel,
      preConfigured: Configured?,
      config: Config,
      serviceConfig: ServiceConfig
    ) {
      self.channel = channel
      self.serviceConfig = serviceConfig
      self.methodConfig = MethodConfigs(serviceConfig: serviceConfig)
      self.config = config
      self.state = Mutex(State())
      self.preConfigured = preConfigured

      if let throttleConfig = serviceConfig.retryThrottling {
        self.retryThrottle = RetryThrottle(policy: throttleConfig)
      } else {
        self.retryThrottle = nil
      }
    }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? {
      return self.methodConfig[descriptor]
    }

    public func connect() async throws {
      switch self.state.withLock({ $0.connect() }) {
      case .configureChannel:
        ()
      case .return:
        return
      }

      do {
        let connection: NIOAsyncChannel<ClientConnectionEvent, Void>
        let streamMultiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

        if let preConfigured = self.preConfigured {
          connection = preConfigured.connection
          streamMultiplexer = preConfigured.multiplexer
        } else {
          (connection, streamMultiplexer) = try await self.channel.eventLoop.submit {
            let config = GRPCChannel.Config(self.config)
            let sync = self.channel.pipeline.syncOperations
            return try sync.configureGRPCClientPipeline(channel: self.channel, config: config)
          }.get()
        }

        switch self.state.withLock({ $0.channelConfigured(multiplexer: streamMultiplexer) }) {
        case .continue:
          // Add a task to run the connection and consume events.
          try? await connection.executeThenClose { inbound, outbound in
            for try await event in inbound {
              switch event {
              case .ready:
                // Start doing RPCs.
                switch self.state.withLock({ $0.ready() }) {
                case .resume(let continuations, let multiplexer):
                  for continuation in continuations {
                    continuation.resume(returning: multiplexer)
                  }
                case .none:
                  ()
                }

              case .closing:
                ()
              }
            }
          }

          switch self.state.withLock({ $0.connectionClosed() }) {
          case .none:
            ()
          case .failQueuedStreams(let continuations):
            for continuation in continuations {
              continuation.resume(
                throwing: RPCError(code: .unavailable, message: "The channel was closed")
              )
            }
          }

        case .shutDown:
          try await self.channel.close()
        }
      } catch {
        switch self.state.withLock({ $0.channelConfigured(multiplexer: nil) }) {
        case .continue:
          ()
        case .shutDown:
          try? await channel.close()
        }
        // Throw the original error.
        throw error
      }
    }

    public func beginGracefulShutdown() {
      switch self.state.withLock({ $0.beginGracefulShutdown() }) {
      case .emitGracefulShutdownEvent:
        // Fire an event into the channel. At this point it will have been configured for gRPC
        // and an appropriate channel handler will consume it to start the graceful shutdown
        // flow.
        let event = ClientConnectionHandler.OutboundEvent.closeGracefully
        self.channel.triggerUserOutboundEvent(event, promise: nil)
      case .none:
        ()
      }
    }

    public func withStream<T>(
      descriptor: MethodDescriptor,
      options: CallOptions,
      _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T where T: Sendable {
      let multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

      switch self.state.withLock({ $0.createStream() }) {
      case .create(let mux):
        multiplexer = mux

      case .throw(let error):
        throw error

      case .enqueue:
        // The transport isn't ready yet: queue the stream.
        let id = QueueEntryID()
        multiplexer = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let action = self.state.withLock {
              $0.enqueue(continuation: continuation, withID: id)
            }

            switch action {
            case .resume(.success(let multiplexer)):
              continuation.resume(returning: multiplexer)
            case .resume(.failure(let error)):
              continuation.resume(throwing: error)
            case .none:
              if Task.isCancelled {
                let action = self.state.withLock { $0.dequeue(id: id) }
                switch action {
                case .dequeued(let continuation):
                  continuation.resume(throwing: CancellationError())
                case .none:
                  ()
                }
              }
            }
          }
        } onCancel: {
          let action = self.state.withLock { $0.dequeue(id: id) }
          switch action {
          case .dequeued(let continuation):
            continuation.resume(throwing: CancellationError())
          case .none:
            ()
          }
        }
      }

      let stream = try await self.makeStream(
        on: multiplexer,
        descriptor: descriptor,
        options: options
      )

      return try await stream.execute { inbound, outbound in
        let rpcStream = RPCStream(
          descriptor: stream.context.descriptor,
          inbound: RPCAsyncSequence<RPCResponsePart, any Error>(wrapping: inbound),
          outbound: RPCWriter.Closable(wrapping: outbound)
        )
        return try await closure(rpcStream, stream.context)
      }
    }

    private func makeStream(
      on multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>,
      descriptor: MethodDescriptor,
      options: CallOptions
    ) async throws(RPCError) -> Connection.Stream {
      // Merge options from the call with those from the service config.
      let methodConfig = self.config(forMethod: descriptor)
      var options = options
      options.formUnion(with: methodConfig)

      let compression: CompressionAlgorithm
      if let override = options.compression {
        compression =
          self.config.compression.enabledAlgorithms.contains(override) ? override : .none
      } else {
        compression = self.config.compression.algorithm
      }

      let maxRequestSize = options.maxRequestMessageBytes ?? Self.defaultMaxRequestMessageSizeBytes

      do {
        let stream = try await multiplexer.openStream { channel in
          channel.eventLoop.makeCompletedFuture {
            let streamHandler = GRPCClientStreamHandler(
              methodDescriptor: descriptor,
              scheme: .http,
              // The value of authority here is being used for the ":authority" pseudo-header. Derive
              // one from the address if we don't already have one.
              authority: self.config.http2.authority,
              outboundEncoding: compression,
              acceptedEncodings: self.config.compression.enabledAlgorithms,
              maxPayloadSize: maxRequestSize
            )
            try channel.pipeline.syncOperations.addHandler(streamHandler)

            return try NIOAsyncChannel(
              wrappingChannelSynchronously: channel,
              configuration: NIOAsyncChannel.Configuration(
                isOutboundHalfClosureEnabled: true,
                inboundType: RPCResponsePart<GRPCNIOTransportBytes>.self,
                outboundType: RPCRequestPart<GRPCNIOTransportBytes>.self
              )
            )
          }.runInitializerIfSet(
            self.config.channelDebuggingCallbacks.onCreateHTTP2Stream,
            on: channel
          )
        }

        let context = ClientContext(
          descriptor: descriptor,
          remotePeer: self.channel.remoteAddressInfo,
          localPeer: self.channel.localAddressInfo
        )

        return Connection.Stream(wrapping: stream, context: context)
      } catch {
        throw RPCError(code: .unavailable, message: "subchannel is unavailable", cause: error)
      }
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ClientTransport where Self == HTTP2ClientTransport.WrappedChannel {
  /// Create a new wrapping client transport from an already connection NIO `Channel`.
  ///
  /// - Parameters:
  ///   - channel: The channel to wrap. The transport takes ownership of the lifetime of the channel
  ///       from this point onwards and is responsible for closing it when the transport is
  ///       finished.
  ///   - config: Configuration for the transport.
  ///   - serviceConfig: Service config controlling how the transport should handle individual
  ///       methods and throttle retries. Note that load-balancing policies are ignored by this
  ///       transport.
  @available(
    *,
    deprecated,
    message: """
      Use 'HTTP2ClientTransport.WrappedChannel.wrapping(config:serviceConfig:makeChannel:)' so the \
      gRPC pipeline is configured before the channel becomes active. The pre-existing init is \
      best-effort and may drop early server frames such as SETTINGS.
      """
  )
  public static func wrapping(
    channel: consuming any Channel,
    config: HTTP2ClientTransport.WrappedChannel.Config = .defaults,
    serviceConfig: ServiceConfig = ServiceConfig()
  ) -> Self {
    HTTP2ClientTransport.WrappedChannel(
      takingOwnershipOf: channel,
      config: config,
      serviceConfig: serviceConfig
    )
  }
}

@available(gRPCSwiftNIOTransport 2.9, *)
extension HTTP2ClientTransport.WrappedChannel {
  /// An opaque handle representing a `Channel` whose pipeline has been configured for gRPC by
  /// ``WrappedChannel/wrapping(config:serviceConfig:makeChannel:)``.
  ///
  /// Returned from the `configure` closure given to `makeChannel` and threaded through to the
  /// closure's return value; do not construct this yourself.
  public struct ConfiguredChannel: Sendable {
    /// The underlying NIO `Channel`.
    public let channel: any Channel

    fileprivate let connection: NIOAsyncChannel<ClientConnectionEvent, Void>
    fileprivate let multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

    fileprivate init(
      channel: any Channel,
      connection: NIOAsyncChannel<ClientConnectionEvent, Void>,
      multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
    ) {
      self.channel = channel
      self.connection = connection
      self.multiplexer = multiplexer
    }
  }

  /// Builds a `WrappedChannel` transport, configuring the gRPC pipeline on a channel you supply.
  ///
  /// The `makeChannel` closure is invoked with a `configure` closure. You must call
  /// `configure(_:)` exactly once before any inbound bytes can flow into the pipeline. In a
  /// bootstrap that means calling it from inside the `channelInitializer`, alongside any pre-gRPC
  /// handlers (TLS, tunnelling, etc.). The returned ``ConfiguredChannel`` must be threaded back
  /// out as the result of `makeChannel`.
  ///
  /// - Parameters:
  ///   - config: Configuration for the transport.
  ///   - serviceConfig: Service config controlling how the transport should handle individual
  ///       methods and throttle retries. Note that load-balancing policies are ignored by this
  ///       transport.
  ///   - makeChannel: A closure to create a `Channel` and configure its pipeline. Must invoke and
  ///       return the result of `configure`.
  /// - Returns: A ``WrappedChannel``.
  public static func wrapping(
    config: Config = .defaults,
    serviceConfig: ServiceConfig = ServiceConfig(),
    makeChannel:
      @Sendable (
        _ configure: @escaping @Sendable (any Channel) -> EventLoopFuture<ConfiguredChannel>
      ) async throws -> ConfiguredChannel
  ) async throws -> Self {
    let configured = try await makeChannel { channel in
      @Sendable
      func doConfigure() throws -> ConfiguredChannel {
        let (connection, mux) = try channel.pipeline.syncOperations.configureGRPCClientPipeline(
          channel: channel,
          config: GRPCChannel.Config(config)
        )
        return ConfiguredChannel(channel: channel, connection: connection, multiplexer: mux)
      }

      if channel.eventLoop.inEventLoop {
        return channel.eventLoop.makeCompletedFuture { try doConfigure() }
      } else {
        return channel.eventLoop.submit { try doConfigure() }
      }
    }

    return Self(
      takingOwnershipOf: configured.channel,
      preConfigured: Configured(
        connection: configured.connection,
        multiplexer: configured.multiplexer
      ),
      config: config,
      serviceConfig: serviceConfig
    )
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ClientTransport where Self == HTTP2ClientTransport.WrappedChannel {
  /// Builds a `WrappedChannel` transport, configuring the gRPC pipeline on a channel you supply.
  ///
  /// See ``HTTP2ClientTransport/WrappedChannel/wrapping(config:serviceConfig:makeChannel:)`` for
  /// details.
  ///
  /// - Parameters:
  ///   - config: Configuration for the transport.
  ///   - serviceConfig: Service config controlling how the transport should handle individual
  ///       methods and throttle retries. Note that load-balancing policies are ignored by this
  ///       transport.
  ///   - makeChannel: A closure to create a `Channel` and configure its pipeline. Must invoke and
  ///       return the result of `configure`.
  /// - Returns: A ``WrappedChannel``.
  public static func wrapping(
    config: HTTP2ClientTransport.WrappedChannel.Config = .defaults,
    serviceConfig: ServiceConfig = ServiceConfig(),
    makeChannel:
      @Sendable (
        _ configure:
          @escaping @Sendable (
            any Channel
          ) -> EventLoopFuture<HTTP2ClientTransport.WrappedChannel.ConfiguredChannel>
      ) async throws -> HTTP2ClientTransport.WrappedChannel.ConfiguredChannel
  ) async throws -> Self {
    return try await HTTP2ClientTransport.WrappedChannel.wrapping(
      config: config,
      serviceConfig: serviceConfig,
      makeChannel: makeChannel
    )
  }
}
