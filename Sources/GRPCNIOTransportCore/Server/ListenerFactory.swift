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

public import NIOCore
internal import NIOExtras

/// Types used by ``HTTP2ServerTransport/ListenerFactory`` implementations to configure
/// NIO channels for use with the gRPC server transport.
///
/// - SeeAlso: ``NIOBasedHTTP2ServerTransport``
@available(gRPCSwiftNIOTransport 2.5, *)
extension HTTP2ServerTransport {
  /// Parameters for configuring a listening (server) channel.
  ///
  /// Instances of this type are provided to ``ListenerFactory/makeListeningChannel(listenerParameters:connectionParameters:)``
  /// implementations. Use ``configureListener(channel:debuggingCallbacks:)`` to apply the
  /// required configuration to the listening channel.
  public struct ListenerParameters: Sendable {
    var quiescingHelper: ServerQuiescingHelper

    /// Configures the listening channel with the necessary handlers for graceful shutdown
    /// and debugging callbacks.
    ///
    /// This should be called from the `serverChannelInitializer` of a bootstrap.
    ///
    /// - Parameters:
    ///   - channel: The listening channel to configure.
    ///   - debuggingCallbacks: Debugging callbacks to invoke after the channel is configured.
    /// - Returns: A future that completes when the channel has been configured.
    public func configureListener(
      channel: any Channel,
      debuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
    ) -> EventLoopFuture<Void> {
      let configured = channel.eventLoop.makeCompletedFuture {
        let quiescingHandler = self.quiescingHelper.makeServerChannelHandler(
          channel: channel
        )
        try channel.pipeline.syncOperations.addHandler(quiescingHandler)
      }

      return configured.runInitializerIfSet(debuggingCallbacks.onBindTCPListener, on: channel)
    }
  }

  /// Parameters for configuring an accepted connection channel.
  ///
  /// Instances of this type are provided to ``ListenerFactory/makeListeningChannel(listenerParameters:connectionParameters:)``
  /// implementations. Use ``configureConnection(channel:compressionConfig:connectionConfig:http2Config:rpcConfig:debuggingCallbacks:usesTLS:requireALPN:)``
  /// to apply the required gRPC HTTP/2 pipeline configuration to each accepted connection channel.
  public struct ConnectionParameters: Sendable {
    /// Configures an accepted connection channel with the gRPC HTTP/2 server pipeline.
    ///
    /// This should be called from the `childChannelInitializer` of a bootstrap.
    ///
    /// - Parameters:
    ///   - channel: The accepted connection channel to configure.
    ///   - compressionConfig: Compression configuration for the connection.
    ///   - connectionConfig: Connection-level configuration.
    ///   - http2Config: HTTP/2 configuration.
    ///   - rpcConfig: RPC-level configuration.
    ///   - debuggingCallbacks: Debugging callbacks to invoke after the channel is configured.
    ///   - usesTLS: Whether TLS is being used on this connection.
    ///   - requireALPN: Whether ALPN negotiation is required.
    /// - Returns: A future that completes with a ``ConnectionChannel`` when the channel
    ///   has been configured.
    public func configureConnection(
      channel: any Channel,
      compressionConfig: HTTP2ServerTransport.Config.Compression,
      connectionConfig: HTTP2ServerTransport.Config.Connection,
      http2Config: HTTP2ServerTransport.Config.HTTP2,
      rpcConfig: HTTP2ServerTransport.Config.RPC,
      debuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks,
      usesTLS: Bool,
      requireALPN: Bool
    ) -> EventLoopFuture<ConnectionChannel> {
      self.configureConnection(
        channel: channel,
        sslHandler: nil,
        compressionConfig: compressionConfig,
        connectionConfig: connectionConfig,
        http2Config: http2Config,
        rpcConfig: rpcConfig,
        debuggingCallbacks: debuggingCallbacks,
        usesTLS: usesTLS,
        requireALPN: requireALPN
      )
    }

    /// Configures an accepted connection channel with the gRPC HTTP/2 server pipeline,
    /// optionally inserting an SSL handler.
    ///
    /// - Parameters:
    ///   - channel: The accepted connection channel to configure.
    ///   - sslHandler: An optional SSL handler to add to the pipeline before configuring
    ///     the gRPC pipeline.
    ///   - compressionConfig: Compression configuration for the connection.
    ///   - connectionConfig: Connection-level configuration.
    ///   - http2Config: HTTP/2 configuration.
    ///   - rpcConfig: RPC-level configuration.
    ///   - debuggingCallbacks: Debugging callbacks to invoke after the channel is configured.
    ///   - usesTLS: Whether TLS is being used on this connection.
    ///   - requireALPN: Whether ALPN negotiation is required.
    /// - Returns: A future that completes with a ``ConnectionChannel`` when the channel
    ///   has been configured.
    package func configureConnection(
      channel: any Channel,
      sslHandler: (any ChannelHandler)?,
      compressionConfig: HTTP2ServerTransport.Config.Compression,
      connectionConfig: HTTP2ServerTransport.Config.Connection,
      http2Config: HTTP2ServerTransport.Config.HTTP2,
      rpcConfig: HTTP2ServerTransport.Config.RPC,
      debuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks,
      usesTLS: Bool,
      requireALPN: Bool
    ) -> EventLoopFuture<ConnectionChannel> {
      let configured = channel.eventLoop.makeCompletedFuture {
        if let sslHandler {
          try channel.pipeline.syncOperations.addHandler(sslHandler)
        }

        let (connection, mux) = try channel.pipeline.syncOperations.configureGRPCServerPipeline(
          channel: channel,
          compressionConfig: compressionConfig,
          connectionConfig: connectionConfig,
          http2Config: http2Config,
          rpcConfig: rpcConfig,
          debugConfig: debuggingCallbacks,
          requireALPN: requireALPN,
          scheme: usesTLS ? .https : .http
        )

        return ConnectionChannel(connection: connection, multiplexer: mux)
      }

      return configured.runInitializerIfSet(debuggingCallbacks.onAcceptTCPConnection, on: channel)
    }
  }

  /// An HTTP/2 connection channel that has been configured for gRPC.
  ///
  /// This type wraps the HTTP/2 connection channel and its stream multiplexer, as returned
  /// by ``ConnectionParameters/configureConnection(channel:compressionConfig:connectionConfig:http2Config:rpcConfig:debuggingCallbacks:usesTLS:requireALPN:)``.
  public struct ConnectionChannel: Sendable {
    let connection: ChannelPipeline.SynchronousOperations.HTTP2ConnectionChannel
    let multiplexer: ChannelPipeline.SynchronousOperations.HTTP2StreamMultiplexer
  }

  /// A factory for creating listening channels that accept HTTP/2 connections.
  ///
  /// Implement this protocol to provide a custom mechanism for accepting connections,
  /// such as XPC-based listeners. The factory is responsible for creating
  /// a `NIOAsyncChannel` that produces ``ConnectionChannel`` values, one for each
  /// accepted connection.
  ///
  /// The factory should use the provided ``ListenerParameters`` to configure the listening
  /// channel and ``ConnectionParameters`` to configure each accepted connection channel.
  ///
  /// - SeeAlso: ``NIOBasedHTTP2ServerTransport``
  public protocol ListenerFactory: Sendable {
    /// Creates a listening channel that produces configured HTTP/2 connection channels.
    ///
    /// - Parameters:
    ///   - listenerParameters: Parameters for configuring the listening channel.
    ///   - connectionParameters: Parameters for configuring each accepted connection channel.
    /// - Returns: A `NIOAsyncChannel` that produces ``ConnectionChannel`` values for
    ///   each accepted connection.
    func makeListeningChannel(
      listenerParameters: ListenerParameters,
      connectionParameters: ConnectionParameters
    ) async throws -> NIOAsyncChannel<ConnectionChannel, Never>
  }
}
