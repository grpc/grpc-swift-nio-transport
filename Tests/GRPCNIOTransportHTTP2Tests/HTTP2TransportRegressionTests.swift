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

import GRPCCore
import GRPCNIOTransportHTTP2
import Testing

struct HTTP2TransportRegressionTests {
  @Test
  @available(gRPCSwiftNIOTransport 2.2, *)
  func testCancelledServerDoesntWedge() async throws {
    // Checks that a gRPC server with an active RPC shuts down when the server task
    // is cancelled. The flavour of transport doesn't matter here so long as it's HTTP/2.

    // Yield a signal so that we know when to cancel the server task. Then sleep
    // so that the RPC is still running when the server task is cancelled.
    let signal = AsyncStream.makeStream(of: Void.self)
    let helloWorld = HelloWorldService { request, _ in
      signal.continuation.yield()
      try await Task.sleep(for: .seconds(60))
      return HelloResponse(message: "Hello, \(request.name)!")
    }

    let server = GRPCServer(
      transport: .http2NIOPosix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .plaintext
      ),
      services: [helloWorld]
    )

    let serverTask = Task {
      try await server.serve()
    }

    let address = try await server.listeningAddress
    let port = try #require(address?.ipv4?.port)

    try await withGRPCClient(
      transport: .http2NIOPosix(
        target: .ipv4(address: "127.0.0.1", port: port),
        transportSecurity: .plaintext
      )
    ) { client in
      let helloWorld = HelloWorld.Client(wrapping: client)
      // Kick this off then wait for the signal.
      let clientTask = Task {
        try await helloWorld.sayHello(HelloRequest(name: "World"))
      }

      for await _ in signal.stream {
        break
      }

      // The RPC is in progress, so cancel the server.
      serverTask.cancel()

      // Now the client should complete.
      #if compiler(>=6.1)
      let error = await #expect(throws: RPCError.self) {
        try await clientTask.value
      }
      #expect(error?.code == .unavailable)
      #else
      await #expect(throws: RPCError.self) {
        try await clientTask.value
      }
      #endif
    }
  }

  @Test
  @available(gRPCSwiftNIOTransport 2.2, *)
  func throwingResolverDoesNotShutdownClient() async throws {
    // This is a test for: https://github.com/grpc/grpc-swift-2/issues/25
    //
    // The client gets wedged if a working channel re-resolves and the resolver throws an error.
    struct CustomResolver: NameResolverFactory {
      struct Target: ResolvableTarget {
        let stream: AsyncThrowingStream<NameResolutionResult, any Error>
      }

      func resolver(for target: Target) -> NameResolver {
        NameResolver(names: RPCAsyncSequence(wrapping: target.stream), updateMode: .push)
      }
    }

    var registry = NameResolverRegistry()
    registry.registerFactory(CustomResolver())

    try await withGRPCServer(
      transport: .http2NIOPosix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .plaintext
      ),
      services: [HelloWorldService()]
    ) { server in
      let address = try #require(try await server.listeningAddress)
      let resolver = AsyncThrowingStream.makeStream(of: NameResolutionResult.self)

      // Send in the server address.
      resolver.continuation.yield(
        NameResolutionResult(endpoints: [Endpoint(addresses: [address])], serviceConfig: nil)
      )

      try await withGRPCClient(
        transport: .http2NIOPosix(
          target: CustomResolver.Target(stream: resolver.stream),
          transportSecurity: .plaintext,
          resolverRegistry: registry
        )
      ) { rawClient in
        let helloWorld = HelloWorld.Client(wrapping: rawClient)
        let reply1 = try await helloWorld.sayHello(HelloRequest(name: "World"))
        #expect(reply1.message == "Hello, World!")

        // Push a failure to the resolver.
        struct ResolutionFailure: Error {}
        resolver.continuation.finish(throwing: ResolutionFailure())

        // Wait a moment for the error to propagate.
        try await Task.sleep(for: .milliseconds(50))
        let reply2 = try await helloWorld.sayHello(HelloRequest(name: "World"))
        #expect(reply2.message == "Hello, World!")
      }
    }
  }
}
