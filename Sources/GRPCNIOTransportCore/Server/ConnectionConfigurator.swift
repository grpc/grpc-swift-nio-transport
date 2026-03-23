/*
 * Copyright 2026, gRPC Authors All rights reserved.
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

@available(gRPCSwiftNIOTransport 2.6, *)
extension HTTP2ServerTransport {
  /// A configurator for accepted connection channels.
  ///
  /// Instances of this type are created by ``HTTP2ServerTransport/Custom`` with the appropriate gRPC configuration already
  /// captured. Use ``configure(channel:tls:)`` to apply the gRPC HTTP/2 pipeline configuration to each accepted
  /// connection channel.
  public struct ConnectionConfigurator: Sendable {
    /// Describes whether TLS is being used on a connection.
    ///
    /// This is provided to ``ConnectionConfigurator/configure(channel:tls:)`` so that the
    /// gRPC pipeline can determine the scheme and whether ALPN is required.
    public struct TLS: Sendable {
      enum Wrapped: Sendable {
        case none
        case configured(requireALPN: Bool)
      }

      let wrapped: Wrapped

      /// No TLS is configured.
      public static var none: Self { Self(wrapped: .none) }

      /// TLS is configured.
      ///
      /// - Parameter requireALPN: Whether ALPN negotiation is required.
      public static func configured(requireALPN: Bool) -> Self {
        Self(wrapped: .configured(requireALPN: requireALPN))
      }

      var usesTLS: Bool {
        switch self.wrapped {
        case .none:
          return false
        case .configured:
          return true
        }
      }

      var requireALPN: Bool {
        switch self.wrapped {
        case .none:
          return false
        case .configured(let requireALPN):
          return requireALPN
        }
      }
    }

    /// An HTTP/2 connection channel that has been configured for gRPC.
    ///
    /// This type wraps the HTTP/2 connection channel and its stream multiplexer, as returned
    /// by ``ConnectionConfigurator/configure(channel:tls:)``.
    public struct ConnectionChannel: Sendable {
      let connection: ChannelPipeline.SynchronousOperations.HTTP2ConnectionChannel
      let multiplexer: ChannelPipeline.SynchronousOperations.HTTP2StreamMultiplexer
    }

    private let compression: HTTP2ServerTransport.Config.Compression
    private let connection: HTTP2ServerTransport.Config.Connection
    private let http2: HTTP2ServerTransport.Config.HTTP2
    private let rpc: HTTP2ServerTransport.Config.RPC
    private let channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks

    package init(
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

    /// Configures an accepted connection channel with the gRPC HTTP/2 server pipeline.
    ///
    /// This should be called from the `childChannelInitializer` of a bootstrap,
    /// *after* any transport-specific handlers (e.g. TLS) have been added.
    ///
    /// - Parameters:
    ///   - channel: The accepted connection channel to configure.
    ///   - tls: Whether TLS is being used on this connection.
    /// - Returns: A future that completes with a ``ConnectionChannel`` when the channel
    ///   has been configured.
    public func configure(
      channel: any Channel,
      tls: TLS
    ) -> EventLoopFuture<ConnectionChannel> {
      let configured = channel.eventLoop.makeCompletedFuture {
        let (connection, mux) = try channel.pipeline.syncOperations.configureGRPCServerPipeline(
          channel: channel,
          compressionConfig: self.compression,
          connectionConfig: self.connection,
          http2Config: self.http2,
          rpcConfig: self.rpc,
          debugConfig: self.channelDebuggingCallbacks,
          requireALPN: tls.requireALPN,
          scheme: tls.usesTLS ? .https : .http
        )
        return ConnectionChannel(connection: connection, multiplexer: mux)
      }
      return configured.runInitializerIfSet(
        self.channelDebuggingCallbacks.onAcceptTCPConnection,
        on: channel
      )
    }
  }
}
