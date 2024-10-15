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
  // - MARK: Tests

  @Test(
    "When using defaults, server does not perform client verification",
    arguments: [TransportKind.posix],
    [TransportKind.posix]
  )
  func testRPC_Defaults_OK(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeDefaultClientTLSConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs
    )
    let serverTransportConfig = self.makeDefaultServerTLSConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs
    )

    try await self.withClientAndServer(
      clientTLSConfig: clientTransportConfig,
      serverTLSConfig: serverTransportConfig
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "When using mTLS defaults, both client and server verify each others' certificates",
    arguments: [TransportKind.posix],
    [TransportKind.posix]
  )
  func testRPC_mTLS_OK(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeMTLSClientTLSConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs,
      serverHostname: "localhost"
    )
    let serverTransportConfig = self.makeMTLSServerTLSConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: true
    )

    try await self.withClientAndServer(
      clientTLSConfig: clientTransportConfig,
      serverTLSConfig: serverTransportConfig
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "Error is surfaced when client fails server verification",
    arguments: [TransportKind.posix],
    [TransportKind.posix]
  )
  // Verification should fail because the custom hostname is missing on the client.
  func testClientFailsServerValidation(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeMTLSClientTLSConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs,
      serverHostname: nil
    )
    let serverTransportConfig = self.makeMTLSServerTLSConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: true
    )

    try await self.withClientAndServer(
      clientTLSConfig: clientTransportConfig,
      serverTLSConfig: serverTransportConfig
    ) { control in
      await #expect {
        try await self.executeUnaryRPC(control: control)
      } throws: { error in
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
    }
  }

  @Test(
    "Error is surfaced when server fails client verification",
    arguments: [TransportKind.posix],
    [TransportKind.posix]
  )
  // Verification should fail because the server does not have trust roots containing the client cert.
  func testServerFailsClientValidation(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeMTLSClientTLSConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs,
      serverHostname: "localhost"
    )
    let serverTransportConfig = self.makeMTLSServerTLSConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: false
    )

    try await self.withClientAndServer(
      clientTLSConfig: clientTransportConfig,
      serverTLSConfig: serverTransportConfig
    ) { control in
      await #expect {
        try await self.executeUnaryRPC(control: control)
      } throws: { error in
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
    }
  }

  // - MARK: Test Utilities

  enum TransportKind: Sendable {
    case posix
  }

  enum TLSConfig {
    enum Client {
      case posix(HTTP2ClientTransport.Posix.Config.TransportSecurity)
    }

    enum Server {
      case posix(HTTP2ServerTransport.Posix.Config.TransportSecurity)
    }
  }

  func makeDefaultClientTLSConfig(
    for transportSecurity: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs
  ) -> TLSConfig.Client {
    switch transportSecurity {
    case .posix:
      return .posix(
        .tls(
          .defaults {
            $0.trustRoots = .certificates([
              .bytes(certificateKeyPairs.server.certificate, format: .der)
            ])
            $0.serverHostname = "localhost"
          }
        )
      )
    }
  }

  func makeMTLSClientTLSConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs,
    serverHostname: String?
  ) -> TLSConfig.Client {
    switch transportKind {
    case .posix:
      return .posix(
        .tls(
          .mTLS(
            certificateChain: [.bytes(certificateKeyPairs.client.certificate, format: .der)],
            privateKey: .bytes(certificateKeyPairs.client.key, format: .der)
          ) {
            $0.trustRoots = .certificates([
              .bytes(certificateKeyPairs.server.certificate, format: .der)
            ])
            $0.serverHostname = serverHostname
          }
        )
      )
    }
  }

  func makeDefaultServerTLSConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs
  ) -> TLSConfig.Server {
    switch transportKind {
    case .posix:
      return .posix(
        .tls(
          .defaults(
            certificateChain: [.bytes(certificateKeyPairs.server.certificate, format: .der)],
            privateKey: .bytes(certificateKeyPairs.server.key, format: .der)
          )
        )
      )
    }
  }

  func makeMTLSServerTLSConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs,
    includeClientCertificateInTrustRoots: Bool
  ) -> TLSConfig.Server {
    switch transportKind {
    case .posix:
      return .posix(
        .tls(
          .mTLS(
            certificateChain: [.bytes(certificateKeyPairs.server.certificate, format: .der)],
            privateKey: .bytes(certificateKeyPairs.server.key, format: .der)
          ) {
            if includeClientCertificateInTrustRoots {
              $0.trustRoots = .certificates([
                .bytes(certificateKeyPairs.client.certificate, format: .der)
              ])
            }
          }
        )
      )
    }
  }

  func withClientAndServer(
    clientTLSConfig: TLSConfig.Client,
    serverTLSConfig: TLSConfig.Server,
    _ test: (ControlClient) async throws -> Void
  ) async throws {
    try await withThrowingDiscardingTaskGroup { group in
      let server = self.makeServer(tlsConfig: serverTLSConfig)

      group.addTask {
        try await server.serve()
      }

      guard let address = try await server.listeningAddress?.ipv4 else {
        Issue.record("Unexpected address to connect to")
        return
      }
      let target: any ResolvableTarget = .ipv4(host: address.host, port: address.port)
      let client = try self.makeClient(tlsConfig: clientTLSConfig, target: target)

      group.addTask {
        try await client.run()
      }

      let control = ControlClient(wrapping: client)
      try await test(control)

      server.beginGracefulShutdown()
      client.beginGracefulShutdown()
    }
  }

  private func makeServer(tlsConfig: TLSConfig.Server) -> GRPCServer {
    let services = [ControlService()]

    switch tlsConfig {
    case .posix(let transportSecurity):
      let server = GRPCServer(
        transport: .http2NIOPosix(
          address: .ipv4(host: "127.0.0.1", port: 0),
          config: .defaults(transportSecurity: transportSecurity)
        ),
        services: services
      )

      return server
    }
  }

  private func makeClient(
    tlsConfig: TLSConfig.Client,
    target: any ResolvableTarget
  ) throws -> GRPCClient {
    let transport: any ClientTransport

    switch tlsConfig {
    case .posix(let transportSecurity):
      transport = try HTTP2ClientTransport.Posix(
        target: target,
        config: .defaults(transportSecurity: transportSecurity) { config in
          config.backoff.initial = .milliseconds(100)
          config.backoff.multiplier = 1
          config.backoff.jitter = 0
        },
        serviceConfig: ServiceConfig()
      )
    }

    return GRPCClient(transport: transport)
  }

  private func executeUnaryRPC(control: ControlClient) async throws {
    let input = ControlInput.with { $0.numberOfMessages = 1 }
    let request = ClientRequest(message: input)
    try await control.unary(request: request) { response in
      #expect(throws: Never.self) { try response.message }
    }
  }
}

struct SelfSignedCertificateKeyPairs {
  struct CertificateKeyPair {
    let certificate: [UInt8]
    let key: [UInt8]
  }

  let server: CertificateKeyPair
  let client: CertificateKeyPair

  init() throws {
    let server = try Self.makeSelfSignedDERCertificateAndPrivateKey(name: "Server Certificate")
    let client = try Self.makeSelfSignedDERCertificateAndPrivateKey(name: "Client Certificate")

    self.server = CertificateKeyPair(certificate: server.cert, key: server.key)
    self.client = CertificateKeyPair(certificate: client.cert, key: client.key)
  }

  private static func makeSelfSignedDERCertificateAndPrivateKey(
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
