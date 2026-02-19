/*
 * Copyright 2025, gRPC Authors All rights reserved.
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

import GRPCNIOTransportCore
import NIOCore
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("NIOSocketAddress ↔ gRPC SocketAddress conversion")
struct NIOSocketAddressConversionTests {

  @Test("gRPC → NIO conversion of scoped IPv6 does not throw")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func scopedIPv6ToNIO() throws {
    #if os(Windows)
    // Scoped IPv6 address handling uses if_indextoname, not available on Windows.
    return
    #else
    let loopback: String
    #if canImport(Darwin)
    loopback = "lo0"
    #else
    loopback = "lo"
    #endif

    guard if_nametoindex(loopback) != 0 else { return }

    // The getaddrinfo path should handle %scope and set sin6_scope_id.
    let grpcAddress = SocketAddress.IPv6(host: "fe80::1%\(loopback)", port: 50051)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 50051)
    #endif
  }

  @Test("Scoped IPv6 round-trip preserves scope ID")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func scopedIPv6RoundTrip() throws {
    #if os(Windows)
    // Scoped IPv6 address handling uses if_indextoname, not available on Windows.
    return
    #else
    let loopback: String
    #if canImport(Darwin)
    loopback = "lo0"
    #else
    loopback = "lo"
    #endif

    guard if_nametoindex(loopback) != 0 else { return }

    let grpcAddress = SocketAddress.IPv6(host: "fe80::1%\(loopback)", port: 50051)

    // gRPC → NIO: getaddrinfo path handles %scope and sets sin6_scope_id.
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    // NIO → gRPC: if_indextoname reconstructs the %scope suffix from sin6_scope_id.
    let roundTripped = GRPCNIOTransportCore.SocketAddress(nioAddress)

    let ipv6 = try #require(roundTripped.ipv6)
    #expect(ipv6.host.contains("%\(loopback)"))
    #expect(ipv6.port == 50051)
    #endif
  }

  @Test("Non-scoped IPv6 uses inet_pton path")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func nonScopedIPv6ToNIO() throws {
    // Addresses without %scope should still work via the original inet_pton path.
    let grpcAddress = SocketAddress.IPv6(host: "::1", port: 443)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 443)
  }

  @Test("Non-scoped IPv4 conversion still works")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func ipv4ToNIO() throws {
    let grpcAddress = SocketAddress.IPv4(host: "127.0.0.1", port: 8080)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 8080)
  }
}
