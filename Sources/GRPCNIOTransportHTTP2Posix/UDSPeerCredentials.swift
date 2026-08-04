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

internal import GRPCNIOTransportCore
internal import NIOCore

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
// glibc guards `struct ucred` and `SO_PEERCRED` behind `_GNU_SOURCE`, which the Glibc module
// doesn't reliably set, so they come from this shim instead.
internal import CGRPCNIOTransportLinux
#elseif canImport(Musl)
internal import Musl
internal import CGRPCNIOTransportLinux
#endif

/// Reads kernel-validated peer credentials from `channel`'s underlying socket.
///
/// Returns `nil` when the channel isn't backed by a Unix domain socket, when it isn't a
/// `SocketOptionProvider`, on platforms without peer-credential support, or on any read failure.
@available(gRPCSwiftNIOTransport 2.0, *)
internal func makeUDSCredentials(
  channel: any Channel
) async -> HTTP2ServerTransport.Posix.UDSCredentials? {
  // Peer credentials only exist for Unix domain sockets, so avoid the socket option reads
  // altogether for any other transport.
  guard case .some(.unixDomainSocket) = channel.localAddress else { return nil }
  guard let provider = channel as? any SocketOptionProvider else { return nil }

  #if canImport(Darwin)
  do {
    // Darwin reports the peer's effective PID and its credentials through two separate options.
    let pid: pid_t = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_LOCAL),
      name: SocketOptionName(LOCAL_PEEREPID)
    ).get()
    let credentials: xucred = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_LOCAL),
      name: SocketOptionName(LOCAL_PEERCRED)
    ).get()
    // `cr_groups` is imported as a fixed-size tuple; the first element is the primary group.
    return HTTP2ServerTransport.Posix.UDSCredentials(
      pid: .init(rawValue: pid),
      uid: .init(rawValue: credentials.cr_uid),
      gid: .init(rawValue: credentials.cr_groups.0)
    )
  } catch {
    return nil
  }
  #elseif canImport(Glibc) || canImport(Musl)
  do {
    let credentials: ucred = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_SOCKET),
      name: SocketOptionName(SO_PEERCRED)
    ).get()
    return HTTP2ServerTransport.Posix.UDSCredentials(
      pid: .init(rawValue: credentials.pid),
      uid: .init(rawValue: credentials.uid),
      gid: .init(rawValue: credentials.gid)
    )
  } catch {
    return nil
  }
  #else
  return nil
  #endif
}
