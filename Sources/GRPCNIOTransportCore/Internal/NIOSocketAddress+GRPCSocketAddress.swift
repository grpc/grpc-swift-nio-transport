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

private import GRPCCore
package import NIOCore

#if canImport(Glibc)
  import Glibc
  import CNIOLinux
#elseif canImport(Musl)
  import Musl
  import CNIOLinux
#elseif canImport(Darwin)
  import Darwin
#endif

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCNIOTransportCore.SocketAddress {
  package init(_ nioSocketAddress: NIOCore.SocketAddress) {
    switch nioSocketAddress {
    case .v4(let address):
      self = .ipv4(
        host: address.host,
        port: nioSocketAddress.port ?? 0
      )

    case .v6(let address):
      #if !os(Windows)
      // Preserve IPv6 scope ID (e.g., for link-local addresses) which inet_ntop drops.
      // The raw sockaddr_in6 stores sin6_scope_id; reconstruct the scoped host string.
      var host = address.host
      let scopeID = address.address.sin6_scope_id
      if scopeID != 0 && !host.contains("%") {
        var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        if if_indextoname(scopeID, &ifname) != nil {
          host = "\(host)%\(String(cString: ifname))"
        }
      }
      self = .ipv6(
        host: host,
        port: nioSocketAddress.port ?? 0
      )
      #else
      self = .ipv6(
        host: address.host,
        port: nioSocketAddress.port ?? 0
      )
      #endif

    case .unixDomainSocket:
      self = .unixDomainSocket(path: nioSocketAddress.pathname ?? "")
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NIOCore.SocketAddress {
  package init(_ socketAddress: SocketAddress) throws {
    if let ipv4 = socketAddress.ipv4 {
      self = try Self(ipv4)
    } else if let ipv6 = socketAddress.ipv6 {
      self = try Self(ipv6)
    } else if let unixDomainSocket = socketAddress.unixDomainSocket {
      self = try Self(unixDomainSocket)
    } else {
      throw RPCError(
        code: .internalError,
        message:
          "Unsupported mapping to NIOCore/SocketAddress for GRPCNIOTransportCore/SocketAddress: \(socketAddress)."
      )
    }
  }

  package init(_ address: SocketAddress.IPv4) throws {
    try self.init(ipAddress: address.host, port: address.port)
  }

  package init(_ address: SocketAddress.IPv6) throws {
    // IPv6 link-local addresses with scope IDs (e.g. "fe80::1%eth0") require
    // special handling: inet_pton (used by init(ipAddress:port:)) doesn't support
    // the %scope suffix, but getaddrinfo does and properly sets sin6_scope_id.
    if address.host.contains("%") {
      var hints = addrinfo()
      hints.ai_family = AF_INET6
      #if os(Linux) && canImport(Glibc)
      hints.ai_socktype = CInt(SOCK_STREAM.rawValue)
      #else
      hints.ai_socktype = SOCK_STREAM
      #endif
      hints.ai_flags = AI_NUMERICHOST
      var result: UnsafeMutablePointer<addrinfo>?
      let status = getaddrinfo(address.host, String(address.port), &hints, &result)
      defer { if result != nil { freeaddrinfo(result) } }
      guard status == 0, let addrInfo = result else {
        throw RPCError(
          code: .internalError,
          message: "Failed to resolve scoped IPv6 address '\(address.host)': \(status)"
        )
      }
      let sockaddr = addrInfo.pointee.ai_addr!.withMemoryRebound(
        to: sockaddr_in6.self, capacity: 1
      ) { $0.pointee }
      try self.init(sockaddr)
    } else {
      try self.init(ipAddress: address.host, port: address.port)
    }
  }

  package init(_ address: SocketAddress.UnixDomainSocket) throws {
    try self.init(unixDomainSocketPath: address.path)
  }
}
