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

import GRPCNIOTransportCore
import Testing

@Suite("DNSResolver")
struct DNSResolverTests {
  @Test(
    "Resolve hostname",
    arguments: [
      ("127.0.0.1", .ipv4(host: "127.0.0.1", port: 80)),
      ("::1", .ipv6(host: "::1", port: 80)),
    ] as [(String, SocketAddress)]
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
  func resolve(host: String, expected: SocketAddress) async throws {
    // Note: This test checks the IPv4 and IPv6 addresses separately (instead of
    // `DNSResolver.resolve(host: "localhost", port: 80)`) because the ordering of the resulting
    // list containing both IP address versions can be different.

    let result = try await DNSResolver.resolve(host: host, port: 80)

    #expect(result == [expected])
  }
}
