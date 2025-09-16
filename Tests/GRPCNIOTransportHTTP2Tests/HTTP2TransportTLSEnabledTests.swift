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

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCNIOTransportHTTP2TransportServices
import NIOCore
import NIOSSL
import SwiftASN1
import Testing
import X509

#if canImport(Network)
import Network
#endif

@Suite("HTTP/2 transport E2E tests with TLS enabled")
struct HTTP2TransportTLSEnabledTests {
  // - MARK: Tests

  @Test(
    "When using defaults, server does not perform client verification",
    arguments: TransportKind.clientsWithTLS,
    TransportKind.serversWithTLS
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
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

  @available(gRPCSwiftNIOTransport 2.0, *)
  final class TransportSpecificInterceptor: ServerInterceptor {
    let clientCert: [UInt8]
    init(_ clientCert: [UInt8]) {
      self.clientCert = clientCert
    }
    func intercept<Input, Output>(
      request: GRPCCore.StreamingServerRequest<Input>,
      context: GRPCCore.ServerContext,
      next:
        @Sendable (GRPCCore.StreamingServerRequest<Input>, GRPCCore.ServerContext) async throws
        -> GRPCCore.StreamingServerResponse<Output>
    ) async throws -> GRPCCore.StreamingServerResponse<Output>
    where Input: Sendable, Output: Sendable {
      let transportSpecific = context.transportSpecific
      let transportSpecificAsPosixContext = try #require(
        transportSpecific as? HTTP2ServerTransport.Posix.Context
      )
      let peerCertificate = try #require(transportSpecificAsPosixContext.peerCertificate)
      var derSerializer = DER.Serializer()
      try peerCertificate.serialize(into: &derSerializer)
      #expect(derSerializer.serializedBytes == self.clientCert)
      return try await next(request, context)
    }
  }

  @Test(
    "Using the mTLS defaults, and with Posix transport, validate we get the peer cert on the server",
    arguments: [TransportKind.posix]
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
  func testRPC_mTLS_TransportContext_OK(supportedTransport: TransportKind) async throws {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let clientConfig = self.makeMTLSClientConfig(
      for: supportedTransport,
      certificateKeyPairs: certificateKeyPairs,
      serverHostname: "localhost"
    )
    let serverConfig = self.makeMTLSServerConfig(
      for: supportedTransport,
      certificateKeyPairs: certificateKeyPairs,
      includeClientCertificateInTrustRoots: true
    )

    try await self.withClientAndServer(
      clientConfig: clientConfig,
      serverConfig: serverConfig,
      interceptors: [TransportSpecificInterceptor(certificateKeyPairs.client.certificate)]
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "When using mTLS defaults, both client and server verify each others' certificates",
    arguments: TransportKind.clientsWithTLS,
    TransportKind.clientsWithTLS
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
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
    "When using mTLS with PEM files, both client and server verify each others' certificates"
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
  func testRPC_mTLS_posixFileBasedCertificates_OK() async throws {
    // Create a new certificate chain that has 4 certificate/key pairs: root, intermediate, client, server
    let certificateChain = try CertificateChain()
    // Tag our certificate files with the function name
    let filePaths = try certificateChain.writeToTemp()
    // Check that the files
    #expect(FileManager.default.fileExists(atPath: filePaths.clientCert))
    #expect(FileManager.default.fileExists(atPath: filePaths.clientKey))
    #expect(FileManager.default.fileExists(atPath: filePaths.serverCert))
    #expect(FileManager.default.fileExists(atPath: filePaths.serverKey))
    #expect(FileManager.default.fileExists(atPath: filePaths.trustRoots))
    // Create configurations
    let clientConfig = self.makeMTLSClientConfig(
      certificatePath: filePaths.clientCert,
      keyPath: filePaths.clientKey,
      trustRootsPath: filePaths.trustRoots,
      serverHostname: CertificateChain.serverName
    )
    let serverConfig = self.makeMTLSServerConfig(
      certificatePath: filePaths.serverCert,
      keyPath: filePaths.serverKey,
      trustRootsPath: filePaths.trustRoots
    )
    // Run the test
    try await self.withClientAndServer(
      clientConfig: clientConfig,
      serverConfig: serverConfig
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test("Custom certification callbacks are used for verification.")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func testRPC_mTLS_customVerificationCallback_OK() async throws {
    // Create a new certificate chain that has 4 certificate/key pairs: root, intermediate, client, server
    let certificateChain = try CertificateChain()
    let certificatesExpectedInCallback = [certificateChain.client.certificate]
    let filePaths = try certificateChain.writeToTemp()

    let clientConfig = self.makeMTLSClientConfig(
      certificatePath: filePaths.clientCert,
      keyPath: filePaths.clientKey,
      trustRootsPath: filePaths.trustRoots,
      serverHostname: CertificateChain.serverName
    )

    // The confirmation lets us check that the callback is used.
    try await confirmation(expectedCount: 1) { confirmation in
      let serverConfig = self.makeMTLSServerConfigWithCallback(
        certificatePath: filePaths.serverCert,
        keyPath: filePaths.serverKey,
        trustRootsPath: filePaths.trustRoots
      ) { certificates, promise in
        let presentedCertificates = certificates.map {
          try! Certificate(derEncoded: $0.toDERBytes())
        }
        #expect(certificatesExpectedInCallback == presentedCertificates)
        // "Verify" the chain and set the certificate.
        promise.succeed(
          .certificateVerified(VerificationMetadata(ValidatedCertificateChain(certificates)))
        )
        // This should be called once.
        confirmation.confirm()
      }

      // Run the test
      try await self.withClientAndServer(
        clientConfig: clientConfig,
        serverConfig: serverConfig
      ) { control in
        await #expect(throws: Never.self) {
          try await self.executeUnaryRPC(control: control)
        }
      }
    }
  }

  @Test("Custom certification callbacks are not called when verification is disabled.")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func testRPC_mTLS_customVerificationCallback_notCalledWhenNoVerificationIsConfigured()
    async throws
  {
    // Create a new certificate chain that has 4 certificate/key pairs: root, intermediate, client, server
    let certificateChain = try CertificateChain()
    let certificatesExpectedInCallback = [certificateChain.client.certificate]
    let filePaths = try certificateChain.writeToTemp()

    let clientConfig = self.makeMTLSClientConfig(
      certificatePath: filePaths.clientCert,
      keyPath: filePaths.clientKey,
      trustRootsPath: filePaths.trustRoots,
      serverHostname: CertificateChain.serverName
    )

    // The confirmation lets us check that the callback is not used.
    try await confirmation(expectedCount: 0) { confirmation in
      let serverConfig = self.makeMTLSServerConfigWithCallback(
        certificatePath: filePaths.serverCert,
        keyPath: filePaths.serverKey,
        trustRootsPath: filePaths.trustRoots,
        certificateVerification: TLSConfig.CertificateVerification.noVerification
      ) { certificates, promise in
        let presentedCertificates = certificates.map {
          try! Certificate(derEncoded: $0.toDERBytes())
        }
        #expect(certificatesExpectedInCallback == presentedCertificates)
        // "Verify" the chain and set the certificate.
        promise.succeed(
          .certificateVerified(VerificationMetadata(ValidatedCertificateChain(certificates)))
        )
        // We expect this never to be called.
        confirmation()
      }

      // Run the test
      try await self.withClientAndServer(
        clientConfig: clientConfig,
        serverConfig: serverConfig
      ) { control in
        await #expect(throws: Never.self) {
          try await self.executeUnaryRPC(control: control)
        }
      }
    }
  }

  @Test("mTLS custom callback verification failure leads to denied authentication")
  @available(gRPCSwiftNIOTransport 2.0, *)
  // Verification should fail because the custom hostname is missing on the client.
  func testRPC_mTLS_customVerificationCallback_Failure() async throws {
    // Create a new certificate chain that has 4 certificate/key pairs: root, intermediate, client, server
    let certificateChain = try CertificateChain()
    let certificatesExpectedInCallback = [certificateChain.client.certificate]
    let filePaths = try certificateChain.writeToTemp()

    let clientConfig = self.makeMTLSClientConfig(
      certificatePath: filePaths.clientCert,
      keyPath: filePaths.clientKey,
      trustRootsPath: filePaths.trustRoots,
      serverHostname: CertificateChain.serverName
    )

    // The confirmation lets us check that the callback is used.
    await confirmation { confirmation in
      let serverConfig = self.makeMTLSServerConfigWithCallback(
        certificatePath: filePaths.serverCert,
        keyPath: filePaths.serverKey,
        trustRootsPath: filePaths.trustRoots
      ) { certificates, promise in
        let presentedCertificates = certificates.map {
          try! Certificate(derEncoded: $0.toDERBytes())
        }
        #expect(certificatesExpectedInCallback == presentedCertificates)
        // We are failing the certificate check here by propagating ".failed"!
        promise.succeed(.failed)
        confirmation.confirm()
      }

      // Run the test
      await #expect {
        try await self.withClientAndServer(
          clientConfig: clientConfig,
          serverConfig: serverConfig
        ) { control in
          try await self.executeUnaryRPC(control: control)
        }
      } throws: { error in
        // Check root error ...
        let rootError = try #require(error as? RPCError)
        #expect(rootError.code == .unavailable)
        #expect(
          rootError.message
            == "The server accepted the TCP connection but closed the connection before completing the HTTP/2 connection preface."
        )

        // ... and the its cause.
        let sslError = try #require(rootError.cause as? BoringSSLError)
        switch sslError {
        case .sslError:
          break
        default:
          Issue.record(
            "Should be a BoringSSLError.sslError error, but was: \(String(describing: rootError.cause))"
          )
        }
        return true
      }
    }
  }

  @available(gRPCSwiftNIOTransport 2.2, *)
  final class ValidatedCertificateChainInterceptor: ServerInterceptor {
    let expectedCertificateChain: [Certificate]
    init(_ expectedCertificateChain: [Certificate]) {
      self.expectedCertificateChain = expectedCertificateChain
    }
    func intercept<Input, Output>(
      request: GRPCCore.StreamingServerRequest<Input>,
      context: GRPCCore.ServerContext,
      next:
        @Sendable (GRPCCore.StreamingServerRequest<Input>, GRPCCore.ServerContext) async throws
        -> GRPCCore.StreamingServerResponse<Output>
    ) async throws -> GRPCCore.StreamingServerResponse<Output>
    where Input: Sendable, Output: Sendable {
      let transportSpecific = context.transportSpecific
      let transportSpecificAsPosixContext = try #require(
        transportSpecific as? HTTP2ServerTransport.Posix.Context
      )

      let peerValidatedCertificateChain = try #require(
        transportSpecificAsPosixContext.peerValidatedCertificateChain
      )
      // The validated certifiacte chain always contains at least one element.
      #expect(!peerValidatedCertificateChain.isEmpty)

      // And these chains should have the same length.
      #expect(peerValidatedCertificateChain.count == self.expectedCertificateChain.count)
      for (lhs, rhs) in zip(peerValidatedCertificateChain, self.expectedCertificateChain) {
        #expect(lhs == rhs)
      }

      // leaf and root should match the first and last element of the expected chain.
      #expect(peerValidatedCertificateChain.leaf == self.expectedCertificateChain.first!)
      #expect(peerValidatedCertificateChain.root == self.expectedCertificateChain.last!)

      return try await next(request, context)
    }
  }

  @Test(
    "When using a custom certificate callback the validated certifiate chain of the peer is available."
  )
  @available(gRPCSwiftNIOTransport 2.2, *)
  func testRPC_mTLS_peerValidatedCertificateChain() async throws {
    // Create a new certificate chain that has 4 certificate/key pairs: root, intermediate, client, server
    let certificateChain = try CertificateChain()
    let expectedCertificateChain = [certificateChain.client.certificate]
    let filePaths = try certificateChain.writeToTemp()

    // Client and server configurations.
    let clientConfig = self.makeMTLSClientConfig(
      certificatePath: filePaths.clientCert,
      keyPath: filePaths.clientKey,
      trustRootsPath: filePaths.trustRoots,
      serverHostname: CertificateChain.serverName
    )
    let serverConfig = self.makeMTLSServerConfigWithCallback(
      certificatePath: filePaths.serverCert,
      keyPath: filePaths.serverKey,
      trustRootsPath: filePaths.trustRoots
    ) { certificates, promise in
      let presentedCertificates = certificates.map {
        try! Certificate(derEncoded: $0.toDERBytes())
      }
      #expect([certificateChain.client.certificate] == presentedCertificates)
      // "Verify" the chain and set the certificate.
      promise.succeed(
        .certificateVerified(VerificationMetadata(ValidatedCertificateChain(certificates)))
      )
    }

    // Run the test. The interceptor checks that we can query the expected certificate chain.
    try await self.withClientAndServer(
      clientConfig: clientConfig,
      serverConfig: serverConfig,
      interceptors: [ValidatedCertificateChainInterceptor(expectedCertificateChain)]
    ) { control in
      await #expect(throws: Never.self) {
        try await self.executeUnaryRPC(control: control)
      }
    }
  }

  @Test(
    "Error is surfaced when client fails server verification",
    arguments: TransportKind.clientsWithTLS,
    TransportKind.clientsWithTLS
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
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

      case .wrappedChannel:
        fatalError("Unsupported")
      }

      return true
    }
  }

  @Test(
    "Error is surfaced when server fails client verification",
    arguments: TransportKind.clientsWithTLS,
    TransportKind.clientsWithTLS
  )
  @available(gRPCSwiftNIOTransport 2.0, *)
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

      case .wrappedChannel:
        fatalError("Unsupported")
      }

      return true
    }
  }

  // - MARK: Test Utilities

  enum TLSEnabledTestsError: Error {
    case failedToImportPKCS12
    case unexpectedListeningAddress
  }

  struct Config<Transport, Security> {
    var security: Security
    var transport: Transport
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
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

  @available(gRPCSwiftNIOTransport 2.0, *)
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

  @available(gRPCSwiftNIOTransport 2.0, *)
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
  @available(gRPCSwiftNIOTransport 2.0, *)
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

  @available(gRPCSwiftNIOTransport 2.0, *)
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

    case .wrappedChannel:
      fatalError("Unsupported")
    }
  }

  #if canImport(Network)
  @available(gRPCSwiftNIOTransport 2.0, *)
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

  @available(gRPCSwiftNIOTransport 2.0, *)
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

    case .wrappedChannel:
      fatalError("Unsupported")
    }
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeMTLSClientConfig(
    certificatePath: String,
    keyPath: String,
    trustRootsPath: String,
    serverHostname: String?
  ) -> ClientConfig {
    var config = self.makeDefaultPlaintextPosixClientConfig()
    config.security = .mTLS(
      certificateChain: [.file(path: certificatePath, format: .pem)],
      privateKey: .file(path: keyPath, format: .pem)
    ) {
      $0.trustRoots = .certificates([
        .file(path: trustRootsPath, format: .pem)
      ])
    }
    config.transport.http2.authority = serverHostname
    return .posix(config)
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeDefaultPlaintextPosixServerConfig() -> ServerConfig.Posix {
    ServerConfig.Posix(security: .plaintext, transport: .defaults)
  }

  #if canImport(Network)
  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeDefaultPlaintextTSServerConfig() -> ServerConfig.TransportServices {
    ServerConfig.TransportServices(security: .plaintext, transport: .defaults)
  }
  #endif

  @available(gRPCSwiftNIOTransport 2.0, *)
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

    case .wrappedChannel:
      fatalError("Unsupported")
    }
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
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

    case .wrappedChannel:
      fatalError("Unsupported")
    }
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeMTLSServerConfig(
    certificatePath: String,
    keyPath: String,
    trustRootsPath: String
  ) -> ServerConfig {
    var config = self.makeDefaultPlaintextPosixServerConfig()
    config.security = .mTLS(
      certificateChain: [.file(path: certificatePath, format: .pem)],
      privateKey: .file(path: keyPath, format: .pem)
    ) {
      $0.trustRoots = .certificates([
        .file(path: trustRootsPath, format: .pem)
      ])
    }
    return .posix(config)
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeMTLSServerConfigWithCallback(
    certificatePath: String,
    keyPath: String,
    trustRootsPath: String,
    certificateVerification: TLSConfig.CertificateVerification = .noHostnameVerification,
    customVerificationCallback:
      @escaping (
        @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>) ->
          Void
      )
  ) -> ServerConfig {
    var config = self.makeDefaultPlaintextPosixServerConfig()
    config.security = .mTLS(
      certificateChain: [.file(path: certificatePath, format: .pem)],
      privateKey: .file(path: keyPath, format: .pem)
    ) {
      $0.clientCertificateVerification = certificateVerification
      $0.trustRoots = .certificates([
        .file(path: trustRootsPath, format: .pem)
      ])
      $0.customVerificationCallback = customVerificationCallback
    }
    return .posix(config)
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  func withClientAndServer(
    clientConfig: ClientConfig,
    serverConfig: ServerConfig,
    interceptors: [any ServerInterceptor] = [],
    _ test: (ControlClient<NIOClientTransport>) async throws -> Void
  ) async throws {
    let serverTransport: NIOServerTransport
    switch serverConfig {
    case .posix(let posix):
      serverTransport = NIOServerTransport(
        .http2NIOPosix(
          address: .ipv4(host: "127.0.0.1", port: 0),
          transportSecurity: posix.security,
          config: posix.transport
        )
      )
    #if canImport(Network)
    case .transportServices(let config):
      serverTransport = NIOServerTransport(
        .http2NIOTS(
          address: .ipv4(host: "127.0.0.1", port: 0),
          transportSecurity: config.security,
          config: config.transport
        )
      )
    #endif
    }

    try await withGRPCServer(
      transport: serverTransport,
      services: [ControlService()],
      interceptors: interceptors
    ) { server in
      guard let address = try await server.listeningAddress?.ipv4 else {
        throw TLSEnabledTestsError.unexpectedListeningAddress
      }

      let target: any ResolvableTarget = .ipv4(address: address.host, port: address.port)
      let clientTransport: NIOClientTransport
      switch clientConfig {
      case .posix(let config):
        clientTransport = try NIOClientTransport(
          .http2NIOPosix(
            target: target,
            transportSecurity: config.security,
            config: config.transport
          )
        )
      #if canImport(Network)
      case .transportServices(let config):
        clientTransport = try NIOClientTransport(
          .http2NIOTS(target: target, transportSecurity: config.security, config: config.transport)
        )
      #endif
      }

      try await withGRPCClient(transport: clientTransport) { client in
        let control = ControlClient(wrapping: client)
        try await test(control)
      }
    }
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func executeUnaryRPC(control: ControlClient<NIOClientTransport>) async throws {
    let input = ControlInput.with { $0.numberOfMessages = 1 }
    let request = ClientRequest(message: input)
    try await control.unary(request: request) { response in
      _ = #expect(throws: Never.self) {
        try response.message
      }
    }
  }
}
