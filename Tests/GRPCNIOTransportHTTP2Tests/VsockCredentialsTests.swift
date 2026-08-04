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
import XCTest

@available(gRPCSwiftNIOTransport 2.10, *)
final class VsockCredentialsTests: XCTestCase {
  /// Records the `vsockCredentials` seen on the server's transport-specific context.
  ///
  /// The credentials are only reachable from inside a server interceptor, so capture them there
  /// and assert on them from the test body once the RPC has completed.
  actor Recorder {
    private(set) var didRun = false
    private(set) var credentials: HTTP2ServerTransport.Posix.VsockCredentials?

    func record(_ credentials: HTTP2ServerTransport.Posix.VsockCredentials?) {
      self.didRun = true
      self.credentials = credentials
    }
  }

  @available(gRPCSwiftNIOTransport 2.10, *)
  final class RecordingInterceptor: ServerInterceptor {
    private let recorder: Recorder

    init(recorder: Recorder) {
      self.recorder = recorder
    }

    func intercept<Input, Output>(
      request: GRPCCore.StreamingServerRequest<Input>,
      context: GRPCCore.ServerContext,
      next:
        @Sendable (GRPCCore.StreamingServerRequest<Input>, GRPCCore.ServerContext) async throws
        -> GRPCCore.StreamingServerResponse<Output>
    ) async throws -> GRPCCore.StreamingServerResponse<Output>
    where Input: Sendable, Output: Sendable {
      let posixContext = context.transportSpecific as? HTTP2ServerTransport.Posix.Context
      await self.recorder.record(posixContext?.vsockCredentials)
      return try await next(request, context)
    }
  }

  /// Runs one unary RPC against a plaintext server bound to `serverAddress` and returns the
  /// `vsockCredentials` the server observed.
  private func recordCredentials(
    serverAddress: GRPCNIOTransportCore.SocketAddress,
    makeTarget: (GRPCNIOTransportCore.SocketAddress) throws -> any ResolvableTarget
  ) async throws -> HTTP2ServerTransport.Posix.VsockCredentials? {
    let recorder = Recorder()

    return try await withThrowingTaskGroup(of: Void.self) { group in
      let server = GRPCServer(
        transport: HTTP2ServerTransport.Posix(
          address: serverAddress,
          transportSecurity: .plaintext
        ),
        services: [ControlService()],
        interceptors: [RecordingInterceptor(recorder: recorder)]
      )

      group.addTask {
        try await server.serve()
      }

      let address = try await server.listeningAddress!

      let client = GRPCClient(
        transport: try HTTP2ClientTransport.Posix(
          target: try makeTarget(address),
          transportSecurity: .plaintext
        )
      )

      group.addTask {
        try await client.runConnections()
      }

      let control = ControlClient(wrapping: client)
      let input = ControlInput.with { $0.numberOfMessages = 1 }
      try await control.unary(request: ClientRequest(message: input)) { response in
        _ = try response.message
      }

      server.beginGracefulShutdown()
      client.beginGracefulShutdown()

      let didRun = await recorder.didRun
      XCTAssertTrue(didRun, "The interceptor never ran, so the RPC didn't reach it")
      return await recorder.credentials
    }
  }

  /// A non-vsock connection must not report vsock credentials.
  ///
  /// The CID is read with `getpeername`, which succeeds on any connected socket. If the address
  /// family weren't checked, a Unix domain socket peer would yield a `sockaddr_un` reinterpreted as
  /// a `sockaddr_vm` and produce a meaningless CID. Callers use the CID to identify the peer, so
  /// this must stay `nil`.
  func testVsockCredentialsAreNilForUnixDomainSocket() async throws {
    let path = "vsock-credentials-uds"
    let credentials = try await self.recordCredentials(
      serverAddress: .unixDomainSocket(path: path)
    ) { _ in
      .unixDomainSocket(path: path)
    }

    XCTAssertNil(credentials)
  }

  /// A non-vsock connection must not report vsock credentials, over TCP as well as UDS.
  func testVsockCredentialsAreNilForIPv4() async throws {
    let credentials = try await self.recordCredentials(
      serverAddress: .ipv4(host: "127.0.0.1", port: 0)
    ) { address in
      let ipv4 = try XCTUnwrap(address.ipv4)
      return .ipv4(address: ipv4.host, port: ipv4.port)
    }

    XCTAssertNil(credentials)
  }

  /// A vsock connection reports the peer's context ID.
  ///
  /// Connects over the vsock loopback transport, where the peer is in the local context, so the
  /// reported CID is `VMADDR_CID_LOCAL`.
  func testVsockCredentialsArePopulatedOverLoopback() async throws {
    try XCTSkipUnless(self.vsockLoopbackAvailable(), "Vsock loopback unavailable")

    // `VMADDR_CID_LOCAL`, which routes to the host that generated the packets. gRPC's `ContextID`
    // exposes `any`, `hypervisor` and `host` but not `local`.
    let localContextID = GRPCNIOTransportCore.SocketAddress.VirtualSocket.ContextID(rawValue: 1)

    let credentials = try await self.recordCredentials(
      serverAddress: .vsock(contextID: .any, port: .any)
    ) { address in
      let vsock = try XCTUnwrap(address.virtualSocket)
      return .vsock(contextID: localContextID, port: vsock.port)
    }

    XCTAssertEqual(try XCTUnwrap(credentials).cid, localContextID)
  }
}
