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
package import NIOExtras

@available(gRPCSwiftNIOTransport 2.6, *)
extension HTTP2ServerTransport {
  /// A configurator for listening (server) channels.
  ///
  /// Instances of this type are created by ``HTTP2ServerTransport/Custom`` with the
  /// appropriate configuration already captured. Use ``configure(channel:)`` to apply
  /// the required configuration to the listening channel.
  public struct ListenerConfigurator: Sendable {
    private let quiescingHelper: ServerQuiescingHelper
    private let channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks

    package init(
      quiescingHelper: ServerQuiescingHelper,
      channelDebuggingCallbacks: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
    ) {
      self.quiescingHelper = quiescingHelper
      self.channelDebuggingCallbacks = channelDebuggingCallbacks
    }

    /// Configures the listening channel with the necessary handlers (e.g. handlers for graceful
    /// shutdown or debugging callbacks).
    ///
    /// This should be called from the `serverChannelInitializer` of a bootstrap.
    ///
    /// - Parameter channel: The listening channel to configure.
    /// - Returns: A future that completes when the channel has been configured.
    public func configure(channel: any Channel) -> EventLoopFuture<Void> {
      let configured = channel.eventLoop.makeCompletedFuture {
        let handler = self.quiescingHelper.makeServerChannelHandler(channel: channel)
        try channel.pipeline.syncOperations.addHandler(handler)
      }
      return configured.runInitializerIfSet(
        self.channelDebuggingCallbacks.onBindTCPListener,
        on: channel
      )
    }
  }
}
