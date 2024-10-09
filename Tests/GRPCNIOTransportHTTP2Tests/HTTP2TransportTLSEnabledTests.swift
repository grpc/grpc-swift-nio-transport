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

import Crypto
import Foundation
import GRPCNIOTransportHTTP2Posix
import NIOSSL
import SwiftASN1
import Testing
import X509

@Suite("HTTP/2 transport E2E tests with TLS enabled")
struct HTTP2TransportTLSEnabledTests {
  // - MARK: Test Utilities

  // A combination of client and server transport kinds.
  struct Transport: Sendable {
    var server: ServerKind
    var client: ClientKind

    enum ClientKind: Sendable {
      case posix(HTTP2ClientTransport.Posix.Config.TransportSecurity)
    }

    enum ServerKind: Sendable {
      case posix(HTTP2ServerTransport.Posix.Config.TransportSecurity)
    }
  }

  func executeUnaryRPCForEachTransportPair(
    transportProvider: (TestSecurity) -> [Transport]
  ) async throws {
    let security = try TestSecurity()
    for pair in transportProvider(security) {
      try await withThrowingTaskGroup(of: Void.self) { group in
        let (server, address) = try await self.runServer(
          in: &group,
          kind: pair.server
        )

        let target: any ResolvableTarget
        if let ipv4 = address.ipv4 {
          target = .ipv4(host: ipv4.host, port: ipv4.port)
        } else if let ipv6 = address.ipv6 {
          target = .ipv6(host: ipv6.host, port: ipv6.port)
        } else if let uds = address.unixDomainSocket {
          target = .unixDomainSocket(path: uds.path)
        } else {
          Issue.record("Unexpected address to connect to")
          return
        }

        let client = try self.makeClient(
          kind: pair.client,
          target: target
        )

        group.addTask {
          try await client.run()
        }

        let control = ControlClient(wrapping: client)
        try await self.executeUnaryRPC(control: control, pair: pair)

        server.beginGracefulShutdown()
        client.beginGracefulShutdown()
      }
    }
  }

  private func runServer(
    in group: inout ThrowingTaskGroup<Void, any Error>,
    kind: Transport.ServerKind
  ) async throws -> (GRPCServer, GRPCNIOTransportHTTP2Posix.SocketAddress) {
    let services = [ControlService()]

    switch kind {
    case .posix(let transportSecurity):
      let server = GRPCServer(
        transport: .http2NIOPosix(
          address: .ipv4(host: "127.0.0.1", port: 0),
          config: .defaults(transportSecurity: transportSecurity)
        ),
        services: services
      )

      group.addTask {
        try await server.serve()
      }

      let address = try await server.listeningAddress!
      return (server, address)
    }
  }

  private func makeClient(
    kind: Transport.ClientKind,
    target: any ResolvableTarget
  ) throws -> GRPCClient {
    let transport: any ClientTransport

    switch kind {
    case .posix(let transportSecurity):
      var serviceConfig = ServiceConfig()
      serviceConfig.loadBalancingConfig = [.roundRobin]
      transport = try HTTP2ClientTransport.Posix(
        target: target,
        config: .defaults(transportSecurity: transportSecurity) { config in
          config.backoff.initial = .milliseconds(100)
          config.backoff.multiplier = 1
          config.backoff.jitter = 0
        },
        serviceConfig: serviceConfig
      )
    }

    return GRPCClient(transport: transport)
  }

  private func executeUnaryRPC(control: ControlClient, pair: Transport) async throws {
    let input = ControlInput.with {
      $0.echoMetadataInHeaders = true
      $0.echoMetadataInTrailers = true
      $0.numberOfMessages = 1
      $0.payloadParameters = .with {
        $0.content = 0
        $0.size = 1024
      }
    }

    let metadata: Metadata = ["test-key": "test-value"]
    let request = ClientRequest(message: input, metadata: metadata)

    try await control.unary(request: request) { response in
      let message = try response.message
      #expect(message.payload == Data(repeating: 0, count: 1024))

      let initial = response.metadata
      #expect(Array(initial["echo-test-key"]) == ["test-value"])

      let trailing = response.trailingMetadata
      #expect(Array(trailing["echo-test-key"]) == ["test-value"])
    }
  }

  // - MARK: Tests

  @Test("When using defaults, server does not perform client verification")
  func testRPC_Defaults_OK() async throws {
    try await self.executeUnaryRPCForEachTransportPair { security in
      [
        HTTP2TransportTLSEnabledTests.Transport(
          server: .posix(
            .tls(
              .defaults(
                certificateChain: [.bytes(security.server.certificate, format: .der)],
                privateKey: .bytes(security.server.key, format: .der)
              )
            )
          ),
          client: .posix(
            .tls(
              .defaults {
                $0.trustRoots = .certificates([.bytes(security.server.certificate, format: .der)])
                $0.serverHostname = "localhost"
              }
            )
          )
        )
      ]
    }
  }

  @Test("When using mTLS defaults, both client and server verify each others' certificates")
  func testRPC_mTLS_OK() async throws {
    try await self.executeUnaryRPCForEachTransportPair { security in
      [
        HTTP2TransportTLSEnabledTests.Transport(
          server: .posix(
            .tls(
              .mTLS(
                certificateChain: [.bytes(security.server.certificate, format: .der)],
                privateKey: .bytes(security.server.key, format: .der)
              ) {
                $0.trustRoots = .certificates([.bytes(security.client.certificate, format: .der)])
              }
            )
          ),
          client: .posix(
            .tls(
              .mTLS(
                certificateChain: [.bytes(security.client.certificate, format: .der)],
                privateKey: .bytes(security.client.key, format: .der)
              ) {
                $0.trustRoots = .certificates([.bytes(security.server.certificate, format: .der)])
                $0.serverHostname = "localhost"
              }
            )
          )
        )
      ]
    }
  }

  @Test("Error is surfaced when client fails server verification")
  // Verification should fail because the custom hostname is missing on the client.
  func testClientFailsServerValidation() async throws {
    await #expect(
      performing: {
        try await self.executeUnaryRPCForEachTransportPair { security in
          [
            HTTP2TransportTLSEnabledTests.Transport(
              server: .posix(
                .tls(
                  .mTLS(
                    certificateChain: [.bytes(security.server.certificate, format: .der)],
                    privateKey: .bytes(security.server.key, format: .der)
                  ) {
                    $0.trustRoots = .certificates([
                      .bytes(security.client.certificate, format: .der)
                    ])
                  }
                )
              ),
              client: .posix(
                .tls(
                  .mTLS(
                    certificateChain: [.bytes(security.client.certificate, format: .der)],
                    privateKey: .bytes(security.client.key, format: .der)
                  ) {
                    $0.trustRoots = .certificates([
                      .bytes(security.server.certificate, format: .der)
                    ])
                  }
                )
              )
            )
          ]
        }
      },
      throws: { error in
        guard let rootError = error as? RPCError else {
          Issue.record("Should be an RPC error")
          return false
        }
        #expect(rootError.code == .unavailable)
        #expect(
          rootError.message
            == "The server accepted the TCP connection but closed the connection before completing the HTTP/2 connection preface."
        )

        guard
          let sslError = rootError.cause as? NIOSSLExtraError,
          case .failedToValidateHostname = sslError
        else {
          Issue.record(
            "Should be a NIOSSLExtraError.failedToValidateHostname error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }

        return true
      }
    )
  }

  @Test("Error is surfaced when server fails client verification")
  // Verification should fail because the server does not have trust roots containing the client cert.
  func testServerFailsClientValidation() async throws {
    await #expect(
      performing: {
        try await self.executeUnaryRPCForEachTransportPair { security in
          [
            HTTP2TransportTLSEnabledTests.Transport(
              server: .posix(
                .tls(
                  .mTLS(
                    certificateChain: [.bytes(security.server.certificate, format: .der)],
                    privateKey: .bytes(security.server.key, format: .der)
                  )
                )
              ),
              client: .posix(
                .tls(
                  .mTLS(
                    certificateChain: [.bytes(security.client.certificate, format: .der)],
                    privateKey: .bytes(security.client.key, format: .der)
                  ) {
                    $0.trustRoots = .certificates([
                      .bytes(security.server.certificate, format: .der)
                    ])
                    $0.serverHostname = "localhost"
                  }
                )
              )
            )
          ]
        }
      },
      throws: { error in
        guard let rootError = error as? RPCError else {
          Issue.record("Should be an RPC error")
          return false
        }
        #expect(rootError.code == .unavailable)
        #expect(
          rootError.message
            == "The server accepted the TCP connection but closed the connection before completing the HTTP/2 connection preface."
        )

        guard
          let sslError = rootError.cause as? NIOSSL.BoringSSLError,
          case .sslError = sslError
        else {
          Issue.record(
            "Should be a NIOSSL.sslError error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }

        return true
      }
    )
  }
}

struct TestSecurity {
  struct Server {
    let certificate: [UInt8]
    let key: [UInt8]
  }

  struct Client {
    let certificate: [UInt8]
    let key: [UInt8]
  }

  let server: Server
  let client: Client

  init() throws {
    let server = try Self.createSelfSignedDERCertificateAndPrivateKey(name: "Server Certificate")
    let client = try Self.createSelfSignedDERCertificateAndPrivateKey(name: "Client Certificate")

    self.server = Server(certificate: server.cert, key: server.key)
    self.client = Client(certificate: client.cert, key: client.key)
  }

  private static func createSelfSignedDERCertificateAndPrivateKey(
    name: String
  ) throws -> (cert: [UInt8], key: [UInt8]) {
    let swiftCryptoKey = P256.Signing.PrivateKey()
    let key = Certificate.PrivateKey(swiftCryptoKey)
    let subjectName = try DistinguishedName { CommonName(name) }
    let issuerName = subjectName
    let now = Date()
    let extensions = try Certificate.Extensions {
      Critical(
        BasicConstraints.isCertificateAuthority(maxPathLength: nil)
      )
      Critical(
        KeyUsage(digitalSignature: true, keyCertSign: true)
      )
      Critical(
        try ExtendedKeyUsage([.serverAuth, .clientAuth])
      )
      SubjectAlternativeNames([.dnsName("localhost")])
    }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-60 * 60),
      notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365),
      issuer: issuerName,
      subject: subjectName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: key
    )

    var serializer = DER.Serializer()
    try serializer.serialize(certificate)

    let certBytes = serializer.serializedBytes
    let keyBytes = try key.serializeAsPEM().derBytes
    return (certBytes, keyBytes)
  }
}
