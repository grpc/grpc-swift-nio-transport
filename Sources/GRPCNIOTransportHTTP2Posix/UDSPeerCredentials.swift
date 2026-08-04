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
    let pid: pid_t = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_LOCAL),
      name: SocketOptionName(LOCAL_PEEREPID)
    ).get()
    let xucred: DarwinXUCred = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_LOCAL),
      name: SocketOptionName(LOCAL_PEERCRED)
    ).get()
    let gid = withUnsafePointer(to: xucred.crGroups) { tuplePtr in
      tuplePtr.withMemoryRebound(to: gid_t.self, capacity: 1) { $0.pointee }
    }
    return HTTP2ServerTransport.Posix.UDSCredentials(
      pid: .init(rawValue: pid),
      uid: .init(rawValue: xucred.crUID),
      gid: .init(rawValue: gid)
    )
  } catch {
    return nil
  }
  #elseif canImport(Glibc) || canImport(Musl)
  do {
    let ucred: LinuxUCred = try await provider.unsafeGetSocketOption(
      level: SocketOptionLevel(SOL_SOCKET),
      name: SocketOptionName(SO_PEERCRED)
    ).get()
    return HTTP2ServerTransport.Posix.UDSCredentials(
      pid: .init(rawValue: ucred.pid),
      uid: .init(rawValue: ucred.uid),
      gid: .init(rawValue: ucred.gid)
    )
  } catch {
    return nil
  }
  #else
  return nil
  #endif
}

#if canImport(Darwin)
/// Mirror of Darwin's `struct xucred` from `<sys/ucred.h>`. Declared locally
/// so we don't depend on the Swift Darwin overlay re-exporting it (which is
/// not guaranteed across SDK versions). Layout must match the kernel:
/// `u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[NGROUPS]`
/// with NGROUPS = 16 on Darwin.
private struct DarwinXUCred: Sendable {
  var crVersion: UInt32 = 0
  var crUID: uid_t = 0
  var crNgroups: Int16 = 0
  private var _pad: Int16 = 0
  var crGroups:
    (
      gid_t, gid_t, gid_t, gid_t, gid_t, gid_t, gid_t, gid_t,
      gid_t, gid_t, gid_t, gid_t, gid_t, gid_t, gid_t, gid_t
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
#endif

#if canImport(Glibc) || canImport(Musl)
/// Mirror of Linux's `struct ucred` from `<sys/socket.h>`. Declared locally
/// because glibc 2.36+ guards the type behind `_GNU_SOURCE`, which the
/// Swift Glibc module does not reliably set.
private struct LinuxUCred: Sendable {
  var pid: pid_t = 0
  var uid: uid_t = 0
  var gid: gid_t = 0
}
#endif
