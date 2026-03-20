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
internal import NIOExtras

@available(gRPCSwiftNIOTransport 2.5, *)
extension HTTP2ServerTransport {
  /// A factory for creating listening channels that accept HTTP/2 connections.
  ///
  /// Implement this protocol to provide a custom mechanism for accepting connections,
  /// such as XPC-based listeners. The factory is responsible for creating
  /// a `NIOAsyncChannel` that produces ``ConnectionConfigurator/ConnectionChannel`` values, one for each
  /// accepted connection.
  ///
  /// The factory should use the provided ``ListenerConfigurator`` to configure the listening
  /// channel and ``ConnectionConfigurator`` to configure each accepted connection channel.
  ///
  /// - SeeAlso: ``HTTP2ServerTransport/Custom``
  public protocol ListenerFactory: Sendable {
    /// The `EventLoopGroup` the listener uses for the connections it creates.
    var eventLoopGroup: any EventLoopGroup { get }

    /// Creates a listening channel that produces configured HTTP/2 connection channels.
    ///
    /// - Parameters:
    ///   - listenerConfigurator: A configurator for the listening channel.
    ///   - connectionConfigurator: A configurator for each accepted connection channel.
    /// - Returns: A `NIOAsyncChannel` that produces ``ConnectionChannel`` values for
    ///   each accepted connection.
    func makeListeningChannel(
      listenerConfigurator: ListenerConfigurator,
      connectionConfigurator: ConnectionConfigurator
    ) async throws -> NIOAsyncChannel<ConnectionConfigurator.ConnectionChannel, Never>
  }
}
