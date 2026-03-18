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

@available(gRPCSwiftNIOTransport 2.5, *)
extension HTTP2ServerTransport {
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

  /// A configurator for accepted connection channels.
  ///
  /// Instances of this type are created by ``HTTP2ServerTransport/Custom`` with the
  /// appropriate gRPC configuration already captured. Use
  /// ``configure(channel:tls:)`` to apply the gRPC HTTP/2 pipeline configuration
  /// to each accepted connection channel.
  public struct ConnectionConfigurator: Sendable {
    /// An HTTP/2 connection channel that has been configured for gRPC.
    ///
    /// This type wraps the HTTP/2 connection channel and its stream multiplexer, as returned
    /// by ``ConnectionConfigurator/configure(channel:tls:)``.
    public struct ConnectionChannel: Sendable {
      let connection: ChannelPipeline.SynchronousOperations.HTTP2ConnectionChannel
      let multiplexer: ChannelPipeline.SynchronousOperations.HTTP2StreamMultiplexer
    }

    private let _configure: @Sendable (any Channel, TLS) -> EventLoopFuture<ConnectionChannel>

    package init(
      configure: @escaping @Sendable (any Channel, TLS) -> EventLoopFuture<ConnectionChannel>
    ) {
      self._configure = configure
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
      self._configure(channel, tls)
    }
  }
}
