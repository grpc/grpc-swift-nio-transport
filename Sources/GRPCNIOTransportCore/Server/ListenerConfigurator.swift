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

@available(gRPCSwiftNIOTransport 2.5, *)
extension HTTP2ServerTransport {
  /// A configurator for listening (server) channels.
  ///
  /// Instances of this type are created by ``NIOBasedHTTP2ServerTransport`` with the
  /// appropriate configuration already captured. Use ``configure(channel:)`` to apply
  /// the required configuration to the listening channel.
  public struct ListenerConfigurator: Sendable {
    private let _configure: @Sendable (any Channel) -> EventLoopFuture<Void>

    package init(
      configure: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) {
      self._configure = configure
    }

    /// Configures the listening channel with the necessary handlers (e.g. handlers for graceful
    /// shutdown or debugging callbacks).
    ///
    /// This should be called from the `serverChannelInitializer` of a bootstrap.
    ///
    /// - Parameter channel: The listening channel to configure.
    /// - Returns: A future that completes when the channel has been configured.
    public func configure(channel: any Channel) -> EventLoopFuture<Void> {
      self._configure(channel)
    }
  }
}
