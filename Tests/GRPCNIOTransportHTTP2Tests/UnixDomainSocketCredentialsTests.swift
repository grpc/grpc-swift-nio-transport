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

import Foundation
import GRPCCore
import GRPCNIOTransportCore
import GRPCNIOTransportHTTP2Posix
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct UnixDomainSocketCredentialsTests {
  /// Runs a single RPC against `service` on a plaintext server bound to `address`.
  @available(gRPCSwiftNIOTransport 2.13, *)
  private func runRPC(
    against service: HelloWorldService,
    boundTo address: GRPCNIOTransportCore.SocketAddress,
    target: @Sendable (GRPCNIOTransportCore.SocketAddress) throws -> any ResolvableTarget
  ) async throws {
    try await withGRPCServer(
      transport: .http2NIOPosix(address: address, transportSecurity: .plaintext),
      services: [service]
    ) { server in
      let listeningAddress = try #require(try await server.listeningAddress)

      try await withGRPCClient(
        transport: .http2NIOPosix(
          target: try target(listeningAddress),
          transportSecurity: .plaintext
        )
      ) { client in
        _ = try await HelloWorld.Client(wrapping: client).sayHello(HelloRequest(name: "World"))
      }
    }
  }

  @Test("Peer credentials describe the connecting process over a Unix domain socket")
  @available(gRPCSwiftNIOTransport 2.13, *)
  func credentialsOverUnixDomainSocket() async throws {
    // Unique per run so that concurrent runs, and a socket file left behind by a crashed one,
    // don't collide.
    let path = "/tmp/uds-peer-credentials-test-\(UUID().uuidString)"
    defer { unlink(path) }

    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      let credentials = try #require(posixContext.unixDomainSocketCredentials)

      // The client runs in this process, so the kernel reports this process' own identity.
      #expect(credentials.processID == UnixDomainSocketCredentials.ProcessID(rawValue: getpid()))
      #expect(credentials.userID == UnixDomainSocketCredentials.UserID(rawValue: geteuid()))
      #expect(credentials.groupID == UnixDomainSocketCredentials.GroupID(rawValue: getegid()))

      return HelloResponse(message: "Hello, \(request.name)!")
    }

    try await self.runRPC(
      against: service,
      boundTo: .unixDomainSocket(path: path),
      target: { _ in .unixDomainSocket(path: path) }
    )
  }

  @Test("Peer credentials are unavailable over TCP")
  @available(gRPCSwiftNIOTransport 2.13, *)
  func credentialsAreUnavailableOverTCP() async throws {
    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      #expect(posixContext.unixDomainSocketCredentials == nil)

      return HelloResponse(message: "Hello, \(request.name)!")
    }

    try await self.runRPC(
      against: service,
      boundTo: .ipv4(host: "127.0.0.1", port: 0),
      target: { address in
        let ipv4 = try #require(address.ipv4)
        return .ipv4(address: ipv4.host, port: ipv4.port)
      }
    )
  }
}
