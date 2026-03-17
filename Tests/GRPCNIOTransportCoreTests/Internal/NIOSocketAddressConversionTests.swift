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

import GRPCNIOTransportCore
import NIOCore
import Testing

@Suite("NIOSocketAddress ↔ gRPC SocketAddress conversion")
struct NIOSocketAddressConversionTests {

  @Test(
    "gRPC → NIO conversion of scoped IPv6 does not throw",
    .disabled(if: System.isWindows)
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
  func scopedIPv6ToNIO() throws {
    let loopback = try #require(System.loopbackInterfaceName)
    try #require(System.isValidInterface(loopback))

    let grpcAddress = SocketAddress.IPv6(host: "fe80::1%\(loopback)", port: 50051)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 50051)
    #expect(nioAddress.ipAddress?.contains("fe80::1") == true, "IP address should contain fe80::1")

    // Verify scope ID is preserved by converting back to gRPC address.
    let roundTripped = GRPCNIOTransportCore.SocketAddress(nioAddress)
    let ipv6 = try #require(roundTripped.ipv6)
    #expect(ipv6.host.contains("%\(loopback)"), "Scope ID should be preserved")
  }

  @Test("Scoped IPv6 round-trip preserves scope ID", .disabled(if: System.isWindows))
  @available(gRPCSwiftNIOTransport 2.0, *)
  func scopedIPv6RoundTrip() throws {
    let loopback = try #require(System.loopbackInterfaceName)
    try #require(System.isValidInterface(loopback))

    let grpcAddress = SocketAddress.IPv6(host: "fe80::1%\(loopback)", port: 50051)

    // gRPC → NIO: getaddrinfo path handles %scope and sets sin6_scope_id.
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    // NIO → gRPC: if_indextoname reconstructs the %scope suffix from sin6_scope_id.
    let roundTripped = GRPCNIOTransportCore.SocketAddress(nioAddress)

    let ipv6 = try #require(roundTripped.ipv6)
    #expect(ipv6.host == "fe80::1%\(loopback)", "Expected exact scope ID preservation")
    #expect(ipv6.port == 50051)
  }

  @Test("Non-scoped IPv6 uses inet_pton path")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func nonScopedIPv6ToNIO() throws {
    let grpcAddress = SocketAddress.IPv6(host: "::1", port: 443)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 443)
    #expect(nioAddress.ipAddress == "::1", "IP address should be ::1")
  }

  @Test("Non-scoped IPv4 conversion still works")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func ipv4ToNIO() throws {
    let grpcAddress = SocketAddress.IPv4(host: "127.0.0.1", port: 8080)
    let nioAddress = try NIOCore.SocketAddress(grpcAddress)

    #expect(nioAddress.port == 8080)
    #expect(nioAddress.ipAddress == "127.0.0.1", "IP address should be 127.0.0.1")
  }
}
