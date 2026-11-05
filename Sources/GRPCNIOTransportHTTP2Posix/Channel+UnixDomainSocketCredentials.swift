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
#elseif canImport(Musl)
internal import Musl
#endif

@available(gRPCSwiftNIOTransport 2.13, *)
extension Channel {
  /// Reads kernel-validated peer credentials from this channel's underlying socket.
  ///
  /// Returns `nil` when UDS peer credentials aren't available.
  internal func unixDomainSocketPeerCredentials() async -> UnixDomainSocketCredentials? {
    // `SO_PEERCRED` and `LOCAL_PEERCRED` don't fail for other socket types: Linux reports a zero
    // process ID with `(uid_t)-1`, and Darwin succeeds without writing anything.
    guard case .unixDomainSocket? = self.localAddress else { return nil }
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
      // first, so bail out rather than report an unset group. A zeroed `xucred` matches the version
      // too, since `XUCRED_VERSION` is zero and NIO zeroes the buffer before the read, so
      // `cr_ngroups` is what rejects it.
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

      // The kernel reports `(uid_t)-1` when it recorded no credentials. The process ID doesn't say
      // the same thing: `pid_vnr` reports zero for a peer this process' PID namespace can't number,
      // whose user and group are still valid.
      guard credentials.uid != UInt32.max, credentials.gid != UInt32.max else { return nil }

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
