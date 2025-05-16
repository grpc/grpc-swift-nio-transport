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
/// protocol. This approach has limitations: as the pre-connected `Channel` is provided to gRPC
/// it isn't possible to transparently reconnect should the connection close. As such this transport
/// offers fewer features than its regular NIO based counterparts.
///
/// ## Providing a suitable Channel
///
/// The transport will add a number of channel handlers to the end of the pipeline of the provided
/// channel. You must ensure that the final channel handler (before being passed into the transport)
/// uses `ByteBuffer` as its `InboundIn` and `OutboundOut` types.
///
/// If you require TLS then it's your responsibility to ensure that the channel is already
/// appropriately configured to use it.
///
/// ## Lifecycle
///
/// By providing a channel to this transport you hand ownership of it to the transport. The
/// transport therefore becomes responsible for closing the channel at the appropriate point
/// in time.
extension HTTP2ClientTransport {
  public final class WrappedChannel: ClientTransport {
    public typealias Bytes = GRPCNIOTransportBytes

    private let channel: any Channel
    private let serviceConfig: ServiceConfig
    private let methodConfig: MethodConfigs
    private let config: Config
    private let state: Mutex<State>

    public let retryThrottle: RetryThrottle?

    /// The default max request message size in bytes, 4 MiB.
    private static var defaultMaxRequestMessageSizeBytes: Int {
      4 * 1024 * 1024
    }

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
    public init(
      takingOwnershipOf channel: consuming any Channel,
      config: Config = .defaults,
      serviceConfig: ServiceConfig = ServiceConfig()
    ) {
      self.channel = channel
      self.serviceConfig = serviceConfig
      self.methodConfig = MethodConfigs(serviceConfig: serviceConfig)
      self.config = config
      self.state = Mutex(State())

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
        let (connection, streamMultiplexer) = try await self.channel.eventLoop.submit {
          let config = GRPCChannel.Config(self.config)
          let sync = self.channel.pipeline.syncOperations
          return try sync.configureGRPCClientPipeline(channel: self.channel, config: config)
        }.get()

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
          case .failQueuedStreams:
            ()
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
        // and an appropriate channel handler will consumer it to start the graceful shutdown
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
              ()
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
