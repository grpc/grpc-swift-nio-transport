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
// `struct ucred` and `SO_PEERCRED` are only declared when `_GNU_SOURCE` is defined, which this
// target does in its C settings (see Package.swift).
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

@available(gRPCSwiftNIOTransport 2.10, *)
extension Channel {
  /// Reads kernel-validated peer credentials from this channel's underlying socket.
  ///
  /// Returns `nil` when the channel isn't backed by a Unix domain socket, when it isn't a
  /// `SocketOptionProvider`, on platforms without peer-credential support, and on any read failure
  /// or unexpected response from the kernel.
  internal func unixDomainSocketPeerCredentials() async -> UnixDomainSocketCredentials? {
    // Peer credentials only exist for Unix domain sockets, so avoid the socket option reads
    // altogether for any other transport.
    guard case .some(.unixDomainSocket) = self.localAddress else { return nil }
    guard let provider = self as? any SocketOptionProvider else { return nil }

    #if canImport(Darwin)
    do {
      // Darwin reports the peer's effective PID and its credentials through two separate options.
      let peerProcessID: pid_t = try await provider.unsafeGetSocketOption(
        level: SocketOptionLevel(SOL_LOCAL),
        name: SocketOptionName(LOCAL_PEEREPID)
      ).get()
      let credentials: xucred = try await provider.unsafeGetSocketOption(
        level: SocketOptionLevel(SOL_LOCAL),
        name: SocketOptionName(LOCAL_PEERCRED)
      ).get()

      // `cr_groups` is only laid out as this version of `xucred` describes if the versions match,
      // and only its first `cr_ngroups` entries are populated. The kernel puts the effective group
      // first, so bail out rather than report an unset group.
      guard credentials.cr_version == UInt32(XUCRED_VERSION), credentials.cr_ngroups > 0 else {
        return nil
      }

      return UnixDomainSocketCredentials(
        processID: UnixDomainSocketCredentials.ProcessID(rawValue: peerProcessID),
        userID: UnixDomainSocketCredentials.UserID(rawValue: credentials.cr_uid),
        groupID: UnixDomainSocketCredentials.GroupID(rawValue: credentials.cr_groups.0)
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
      return UnixDomainSocketCredentials(
        processID: UnixDomainSocketCredentials.ProcessID(rawValue: credentials.pid),
        userID: UnixDomainSocketCredentials.UserID(rawValue: credentials.uid),
        groupID: UnixDomainSocketCredentials.GroupID(rawValue: credentials.gid)
      )
    } catch {
      return nil
    }
    #else
    return nil
    #endif
  }
}
