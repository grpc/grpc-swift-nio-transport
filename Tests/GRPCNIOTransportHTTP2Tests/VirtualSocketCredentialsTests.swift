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

import GRPCCore
import GRPCNIOTransportCore
import GRPCNIOTransportHTTP2Posix
import Testing

struct VirtualSocketCredentialsTests {
  /// Runs a single RPC against `service` on a plaintext server bound to `address`.
  ///
  /// The credentials are only reachable from the server side of an RPC, so each test asserts from
  /// within its service implementation and uses this to drive it with a client.
  @available(gRPCSwiftNIOTransport 2.10, *)
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

  /// A vsock connection reports the peer's context ID.
  ///
  /// The connection is made over the vsock loopback transport, so the peer is in the local context
  /// and the reported context ID is `VMADDR_CID_LOCAL`.
  @Test(
    "Peer credentials describe the connecting context over a virtual socket",
    .enabled(if: vsockLoopbackAvailable(), "Vsock loopback is unavailable")
  )
  @available(gRPCSwiftNIOTransport 2.10, *)
  func credentialsOverVirtualSocket() async throws {
    // `VMADDR_CID_LOCAL`, which routes to the host that generated the packets. gRPC's `ContextID`
    // exposes `any`, `hypervisor` and `host`, but not `local`.
    let localContextID = GRPCNIOTransportCore.SocketAddress.VirtualSocket.ContextID(rawValue: 1)
    // NIO's `SocketAddress` can't represent a vsock address, so the server's listening address is
    // whatever it was configured with and binding `.any` would leave the client with no port to
    // connect to. That forces a fixed port, so use one unlikely to be in use.
    let port = GRPCNIOTransportCore.SocketAddress.VirtualSocket.Port(rawValue: 55123)

    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      let credentials = try #require(posixContext.virtualSocketCredentials)
      #expect(credentials.contextID == localContextID)

      return HelloResponse(message: "Hello, \(request.name)!")
    }

    try await self.runRPC(
      against: service,
      boundTo: .vsock(contextID: .any, port: port),
      target: { _ in .vsock(contextID: localContextID, port: port) }
    )
  }

  /// A non-vsock connection must not report vsock credentials.
  ///
  /// The context ID is read with `getpeername`, which succeeds on any connected socket. If the
  /// address family weren't checked then a Unix domain socket peer would yield a `sockaddr_un`
  /// reinterpreted as a `sockaddr_vm` and produce a meaningless context ID. Callers use the context
  /// ID to identify the peer, so this must stay `nil`.
  @Test("Peer credentials are unavailable over a Unix domain socket")
  @available(gRPCSwiftNIOTransport 2.10, *)
  func credentialsAreUnavailableOverUnixDomainSocket() async throws {
    let path = "/tmp/vsock-credentials-uds-test"

    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      #expect(posixContext.virtualSocketCredentials == nil)

      return HelloResponse(message: "Hello, \(request.name)!")
    }

    try await self.runRPC(
      against: service,
      boundTo: .unixDomainSocket(path: path),
      target: { _ in .unixDomainSocket(path: path) }
    )
  }

  @Test("Peer credentials are unavailable over TCP")
  @available(gRPCSwiftNIOTransport 2.10, *)
  func credentialsAreUnavailableOverTCP() async throws {
    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      #expect(posixContext.virtualSocketCredentials == nil)

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
