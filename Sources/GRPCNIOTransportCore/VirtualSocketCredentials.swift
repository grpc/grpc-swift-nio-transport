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

/// Identifies the peer at the far end of a virtual socket ('vsock') connection.
///
/// The peer's port isn't included: it's assigned per connection, so it doesn't identify the peer.
@available(gRPCSwiftNIOTransport 2.10, *)
public struct VirtualSocketCredentials: Hashable, Sendable {
  /// The context ID of the peer.
  public var contextID: SocketAddress.VirtualSocket.ContextID

  /// Creates credentials describing the peer of a virtual socket connection.
  ///
  /// - Parameter contextID: The context ID of the peer.
  public init(contextID: SocketAddress.VirtualSocket.ContextID) {
    self.contextID = contextID
  }
}
