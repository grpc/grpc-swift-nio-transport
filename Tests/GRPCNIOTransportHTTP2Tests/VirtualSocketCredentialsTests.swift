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
  /// A vsock connection reports the peer's context ID.
  ///
  /// The connection is made over the vsock loopback transport, so the peer is in the local context
  /// and the reported context ID is `VMADDR_CID_LOCAL`.
  ///
  /// The credentials are only reachable from the server side of an RPC, so the assertions live in
  /// the service implementation and a client drives them.
  @Test(
    "Peer credentials describe the connecting context over a virtual socket",
    .enabled(if: vsockLoopbackAvailable(), "Vsock loopback is unavailable")
  )
  @available(gRPCSwiftNIOTransport 2.10, *)
  func credentialsOverVirtualSocket() async throws {
    // NIO's `SocketAddress` can't represent a vsock address, so a vsock listener has no address to
    // report and the port can't be left to the kernel to pick. It's random rather than fixed so
    // that concurrent runs don't collide on it.
    let port = GRPCNIOTransportCore.SocketAddress.VirtualSocket.Port(
      Int.random(in: 32768 ..< 65536)
    )

    let service = HelloWorldService { request, context in
      let posixContext = try #require(
        context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      let credentials = try #require(posixContext.virtualSocketCredentials)
      #expect(credentials.contextID == .local)

      return HelloResponse(message: "Hello, \(request.name)!")
    }

    try await withGRPCServer(
      transport: .http2NIOPosix(
        address: .vsock(contextID: .any, port: port),
        transportSecurity: .plaintext
      ),
      services: [service]
    ) { _ in
      try await withGRPCClient(
        transport: .http2NIOPosix(
          target: .vsock(contextID: .local, port: port),
          transportSecurity: .plaintext
        )
      ) { client in
        _ = try await HelloWorld.Client(wrapping: client).sayHello(HelloRequest(name: "World"))
      }
    }
  }
}
