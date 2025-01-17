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

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCNIOTransportHTTP2TransportServices
import NIOSSL
import Testing

#if canImport(Network)
import Network
#endif

@Suite("HTTP/2 transport E2E tests with TLS enabled")
struct HTTP2TransportTLSEnabledTests {
  // - MARK: Tests

  @Test(
    "When using defaults, server does not perform client verification",
    arguments: TransportKind.supported,
    TransportKind.supported
  )
  func testRPC_Defaults_OK(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientConfig = self.makeDefaultTLSClientConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs
    )
    let serverConfig = self.makeDefaultTLSServerConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs
    )

    try await self.withClientAndServer(
      clientConfig: clientConfig,
      serverConfig: serverConfig
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "When using mTLS defaults, both client and server verify each others' certificates",
    arguments: TransportKind.supported,
    TransportKind.supported
  )
  func testRPC_mTLS_OK(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientConfig = self.makeMTLSClientConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs,
      serverHostname: "localhost"
    )
    let serverConfig = self.makeMTLSServerConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: true
    )

    try await self.withClientAndServer(
      clientConfig: clientConfig,
      serverConfig: serverConfig
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "Error is surfaced when client fails server verification",
    arguments: TransportKind.supported,
    TransportKind.supported
  )
  // Verification should fail because the custom hostname is missing on the client.
  func testClientFailsServerValidation(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeDefaultTLSClientConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs,
      authority: "wrong-hostname"
    )
    let serverTransportConfig = self.makeDefaultTLSServerConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs
    )

    await #expect {
      try await self.withClientAndServer(
        clientConfig: clientTransportConfig,
        serverConfig: serverTransportConfig
      ) { control in
        try await self.executeUnaryRPC(control: control)
      }
    } throws: { error in
      let rootError = try #require(error as? RPCError)
      #expect(rootError.code == .unavailable)

      switch clientTransport {
      case .posix:
        #expect(
          rootError.message
            == "The server accepted the TCP connection but closed the connection before completing the HTTP/2 connection preface."
        )
        let sslError = try #require(rootError.cause as? NIOSSLExtraError)
        guard sslError == .failedToValidateHostname else {
          Issue.record(
            "Should be a NIOSSLExtraError.failedToValidateHostname error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }

      #if canImport(Network)
      case .transportServices:
        #expect(rootError.message.starts(with: "Could not establish a connection to"))
        let nwError = try #require(rootError.cause as? NWError)
        guard case .tls(Security.errSSLBadCert) = nwError else {
          Issue.record(
            "Should be a NWError.tls(-9808/errSSLBadCert) error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }
      #endif
      }

      return true
    }
  }

  @Test(
    "Error is surfaced when server fails client verification",
    arguments: TransportKind.supported,
    TransportKind.supported
  )
  // Verification should fail because the client does not offer a cert that
  // the server can use for mutual verification.
  func testServerFailsClientValidation(
    clientTransport: TransportKind,
    serverTransport: TransportKind
  ) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientTransportConfig = self.makeDefaultTLSClientConfig(
      for: clientTransport,
      certificateKeyPairs: certificateKeyPairs
    )
    let serverTransportConfig = self.makeMTLSServerConfig(
      for: serverTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: true
    )

    await #expect {
      try await self.withClientAndServer(
        clientConfig: clientTransportConfig,
        serverConfig: serverTransportConfig
      ) { control in
        try await self.executeUnaryRPC(control: control)
      }
    } throws: { error in
      let rootError = try #require(error as? RPCError)
      #expect(rootError.code == .unavailable)
      #expect(
        rootError.message
          == "The server accepted the TCP connection but closed the connection before completing the HTTP/2 connection preface."
      )

      switch clientTransport {
      case .posix:
        let sslError = try #require(rootError.cause as? NIOSSL.BoringSSLError)
        guard case .sslError = sslError else {
          Issue.record(
            "Should be a NIOSSL.sslError error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }

      #if canImport(Network)
      case .transportServices:
        let nwError = try #require(rootError.cause as? NWError)
        guard case .tls(Security.errSSLPeerCertUnknown) = nwError else {
          // When the TLS handshake fails, the connection will be closed from the client.
          // Network.framework will generally surface the right SSL error (in this case, an "unknown
          // certificate" from the server), but it will sometimes instead return the broken pipe
          // error caused by the underlying TLS handshake handler closing the connection:
          // we should tolerate this.
          if case .posix(POSIXErrorCode.EPIPE) = nwError {
            return true
          }

          Issue.record(
            "Should be a NWError.tls(-9829/errSSLPeerCertUnknown) error, but was: \(String(describing: rootError.cause))"
          )
          return false
        }
      #endif
      }

      return true
    }
  }

  // - MARK: Test Utilities

  enum TLSEnabledTestsError: Error {
    case failedToImportPKCS12
    case unexpectedListeningAddress
    case serverError(cause: any Error)
    case clientError(cause: any Error)
  }

  enum TransportKind: Sendable {
    case posix
    #if canImport(Network)
    case transportServices
    #endif

    static var supported: [TransportKind] {
      #if canImport(Network)
      return [.posix, .transportServices]
      #else
      return [.posix]
      #endif
    }
  }

  struct Config<Transport, Security> {
    var security: Security
    var transport: Transport
  }

  enum ClientConfig {
    typealias Posix = Config<
      HTTP2ClientTransport.Posix.Config,
      HTTP2ClientTransport.Posix.TransportSecurity
    >
    case posix(Posix)

    #if canImport(Network)
    typealias TransportServices = Config<
      HTTP2ClientTransport.TransportServices.Config,
      HTTP2ClientTransport.TransportServices.TransportSecurity
    >
    case transportServices(TransportServices)
    #endif
  }

  enum ServerConfig {
    typealias Posix = Config<
      HTTP2ServerTransport.Posix.Config,
      HTTP2ServerTransport.Posix.TransportSecurity
    >
    case posix(Posix)

    #if canImport(Network)
    typealias TransportServices = Config<
      HTTP2ServerTransport.TransportServices.Config,
      HTTP2ServerTransport.TransportServices.TransportSecurity
    >
    case transportServices(TransportServices)
    #endif
  }

  private func makeDefaultPlaintextPosixClientConfig() -> ClientConfig.Posix {
    ClientConfig.Posix(
      security: .plaintext,
      transport: .defaults { config in
        config.backoff.initial = .milliseconds(100)
        config.backoff.multiplier = 1
        config.backoff.jitter = 0
      }
    )
  }

  #if canImport(Network)
  private func makeDefaultPlaintextTSClientConfig() -> ClientConfig.TransportServices {
    ClientConfig.TransportServices(
      security: .plaintext,
      transport: .defaults { config in
        config.backoff.initial = .milliseconds(100)
        config.backoff.multiplier = 1
        config.backoff.jitter = 0
      }
    )
  }
  #endif

  private func makeDefaultTLSClientConfig(
    for transportSecurity: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs,
    authority: String? = "localhost"
  ) -> ClientConfig {
    switch transportSecurity {
    case .posix:
      var config = self.makeDefaultPlaintextPosixClientConfig()
      config.security = .tls {
        $0.trustRoots = .certificates([
          .bytes(certificateKeyPairs.server.certificate, format: .der)
        ])
      }
      config.transport.http2.authority = authority
      return .posix(config)

    #if canImport(Network)
    case .transportServices:
      var config = self.makeDefaultPlaintextTSClientConfig()
      config.security = .tls {
        $0.trustRoots = .certificates([
          .bytes(certificateKeyPairs.server.certificate, format: .der)
        ])
      }
      config.transport.http2.authority = authority
      return .transportServices(config)
    #endif
    }
  }

  #if canImport(Network)
  private func makeSecIdentityProvider(
    certificateBytes: [UInt8],
    privateKeyBytes: [UInt8]
  ) throws -> SecIdentity {
    let password = "somepassword"
    let bundle = NIOSSLPKCS12Bundle(
      certificateChain: [try NIOSSLCertificate(bytes: certificateBytes, format: .der)],
      privateKey: try NIOSSLPrivateKey(bytes: privateKeyBytes, format: .der)
    )
    let pkcs12Bytes = try bundle.serialize(passphrase: password.utf8)
    let options =
      [
        kSecImportExportPassphrase as String: password,
        kSecImportToMemoryOnly: kCFBooleanTrue!,
      ] as [AnyHashable: Any]
    var rawItems: CFArray?
    let status = SecPKCS12Import(
      Data(pkcs12Bytes) as CFData,
      options as CFDictionary,
      &rawItems
    )
    guard status == errSecSuccess else {
      Issue.record("Failed to import PKCS12 bundle: status \(status).")
      throw TLSEnabledTestsError.failedToImportPKCS12
    }
    let items = rawItems! as! [[String: Any]]
    let firstItem = items[0]
    let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity
    return identity
  }
  #endif

  private func makeMTLSClientConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs,
    serverHostname: String?
  ) -> ClientConfig {
    switch transportKind {
    case .posix:
      var config = self.makeDefaultPlaintextPosixClientConfig()
      config.security = .mTLS(
        certificateChain: [.bytes(certificateKeyPairs.client.certificate, format: .der)],
        privateKey: .bytes(certificateKeyPairs.client.key, format: .der)
      ) {
        $0.trustRoots = .certificates([
          .bytes(certificateKeyPairs.server.certificate, format: .der)
        ])
      }
      config.transport.http2.authority = serverHostname
      return .posix(config)

    #if canImport(Network)
    case .transportServices:
      var config = self.makeDefaultPlaintextTSClientConfig()
      config.security = .mTLS {
        try self.makeSecIdentityProvider(
          certificateBytes: certificateKeyPairs.client.certificate,
          privateKeyBytes: certificateKeyPairs.client.key
        )
      } configure: {
        $0.trustRoots = .certificates([
          .bytes(certificateKeyPairs.server.certificate, format: .der)
        ])
      }
      config.transport.http2.authority = serverHostname
      return .transportServices(config)
    #endif
    }
  }

  private func makeDefaultPlaintextPosixServerConfig() -> ServerConfig.Posix {
    ServerConfig.Posix(security: .plaintext, transport: .defaults)
  }

  #if canImport(Network)
  private func makeDefaultPlaintextTSServerConfig() -> ServerConfig.TransportServices {
    ServerConfig.TransportServices(security: .plaintext, transport: .defaults)
  }
  #endif

  private func makeDefaultTLSServerConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs
  ) -> ServerConfig {
    switch transportKind {
    case .posix:
      var config = self.makeDefaultPlaintextPosixServerConfig()
      config.security = .tls(
        certificateChain: [.bytes(certificateKeyPairs.server.certificate, format: .der)],
        privateKey: .bytes(certificateKeyPairs.server.key, format: .der)
      )
      return .posix(config)

    #if canImport(Network)
    case .transportServices:
      var config = self.makeDefaultPlaintextTSServerConfig()
      config.security = .tls {
        try self.makeSecIdentityProvider(
          certificateBytes: certificateKeyPairs.server.certificate,
          privateKeyBytes: certificateKeyPairs.server.key
        )
      }
      return .transportServices(config)
    #endif
    }
  }

  private func makeMTLSServerConfig(
    for transportKind: TransportKind,
    certificateKeyPairs: SelfSignedCertificateKeyPairs,
    includeClientCertificateInTrustRoots: Bool
  ) -> ServerConfig {
    switch transportKind {
    case .posix:
      var config = self.makeDefaultPlaintextPosixServerConfig()
      config.security = .mTLS(
        certificateChain: [.bytes(certificateKeyPairs.server.certificate, format: .der)],
        privateKey: .bytes(certificateKeyPairs.server.key, format: .der)
      ) {
        if includeClientCertificateInTrustRoots {
          $0.trustRoots = .certificates([
            .bytes(certificateKeyPairs.client.certificate, format: .der)
          ])
        }
      }
      return .posix(config)

    #if canImport(Network)
    case .transportServices:
      var config = self.makeDefaultPlaintextTSServerConfig()
      config.security = .mTLS {
        try self.makeSecIdentityProvider(
          certificateBytes: certificateKeyPairs.server.certificate,
          privateKeyBytes: certificateKeyPairs.server.key
        )
      } configure: {
        if includeClientCertificateInTrustRoots {
          $0.trustRoots = .certificates([
            .bytes(certificateKeyPairs.client.certificate, format: .der)
          ])
        }
      }
      return .transportServices(config)
    #endif
    }
  }

  func withClientAndServer(
    clientConfig: ClientConfig,
    serverConfig: ServerConfig,
    _ test: (ControlClient) async throws -> Void
  ) async throws {
    try await withThrowingDiscardingTaskGroup { group in
      let server = self.makeServer(config: serverConfig)

      group.addTask {
        do {
          try await server.serve()
        } catch {
          throw TLSEnabledTestsError.serverError(cause: error)
        }
      }

      guard let address = try await server.listeningAddress?.ipv4 else {
        throw TLSEnabledTestsError.unexpectedListeningAddress
      }

      let target: any ResolvableTarget = .ipv4(host: address.host, port: address.port)
      let client = try self.makeClient(config: clientConfig, target: target)

      group.addTask {
        do {
          try await client.runConnections()
        } catch {
          throw TLSEnabledTestsError.clientError(cause: error)
        }
      }

      let control = ControlClient(wrapping: client)
      try await test(control)

      client.beginGracefulShutdown()
      server.beginGracefulShutdown()
    }
  }

  private func makeServer(config: ServerConfig) -> GRPCServer {
    let services = [ControlService()]

    switch config {
    case .posix(let config):
      return GRPCServer(
        transport: .http2NIOPosix(
          address: .ipv4(host: "127.0.0.1", port: 0),
          transportSecurity: config.security,
          config: config.transport
        ),
        services: services
      )

    #if canImport(Network)
    case .transportServices(let config):
      return GRPCServer(
        transport: .http2NIOTS(
          address: .ipv4(host: "127.0.0.1", port: 0),
          transportSecurity: config.security,
          config: config.transport
        ),
        services: services
      )
    #endif
    }
  }

  private func makeClient(
    config: ClientConfig,
    target: any ResolvableTarget
  ) throws -> GRPCClient {
    let transport: any ClientTransport

    switch config {
    case .posix(let config):
      transport = try HTTP2ClientTransport.Posix(
        target: target,
        transportSecurity: config.security,
        config: config.transport,
        serviceConfig: ServiceConfig()
      )

    #if canImport(Network)
    case .transportServices(let config):
      transport = try HTTP2ClientTransport.TransportServices(
        target: target,
        transportSecurity: config.security,
        config: config.transport,
        serviceConfig: ServiceConfig()
      )
    #endif
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
