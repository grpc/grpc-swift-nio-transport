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

package import NIOCore
package import NIOHTTP2
internal import NIOPosix

@available(gRPCSwiftNIOTransport 2.0, *)
package protocol HTTP2Connector: Sendable {
  /// Attempt to establish a connection to the given address.
  ///
  /// - Parameters:
  ///   - address: The address to connect to.
  ///   - sniServerHostname: The name of the server used for the TLS SNI extension (if applicable).
  func establishConnection(
    to address: SocketAddress,
    sniServerHostname: String?
  ) async throws -> HTTP2Connection
}

@available(gRPCSwiftNIOTransport 2.0, *)
package struct HTTP2Connection: Sendable {
  /// The underlying TCP connection wrapped up for use with gRPC.
  var channel: NIOAsyncChannel<ClientConnectionEvent, Void>

  /// An HTTP/2 stream multiplexer.
  var multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>

  /// A callback which is invoked when creating an HTTP/2 stream.
  var onCreateHTTP2Stream: (@Sendable (any Channel) -> EventLoopFuture<Void>)?

  /// Whether the connection is insecure (i.e. plaintext).
  var isPlaintext: Bool

  package init(
    channel: NIOAsyncChannel<ClientConnectionEvent, Void>,
    multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>,
    isPlaintext: Bool,
    onCreateHTTP2Stream: (@Sendable (any Channel) -> EventLoopFuture<Void>)?
  ) {
    self.channel = channel
    self.multiplexer = multiplexer
    self.isPlaintext = isPlaintext
    self.onCreateHTTP2Stream = onCreateHTTP2Stream
  }
}
