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

#if canImport(Network)
import GRPCCore
import GRPCNIOTransportCore
import GRPCNIOTransportHTTP2TransportServices
import XCTest
import NIOSSL

@available(gRPCSwiftNIOTransport 1.0, *)
final class HTTP2TransportNIOTransportServicesTests: XCTestCase {
  func testGetListeningAddress_IPv4() async throws {
    let transport = GRPCNIOTransportCore.HTTP2ServerTransport.TransportServices(
      address: .ipv4(host: "0.0.0.0", port: 0),
      transportSecurity: .plaintext
    )

    try await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        try await transport.listen { _, _ in }
      }

      group.addTask {
        let address = try await transport.listeningAddress
        let ipv4Address = try XCTUnwrap(address.ipv4)
        XCTAssertNotEqual(ipv4Address.port, 0)
        transport.beginGracefulShutdown()
      }
    }
  }

  func testGetListeningAddress_IPv6() async throws {
    let transport = GRPCNIOTransportCore.HTTP2ServerTransport.TransportServices(
      address: .ipv6(host: "::1", port: 0),
      transportSecurity: .plaintext
    )

    try await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        try await transport.listen { _, _ in }
      }

      group.addTask {
        let address = try await transport.listeningAddress
        let ipv6Address = try XCTUnwrap(address.ipv6)
        XCTAssertNotEqual(ipv6Address.port, 0)
        transport.beginGracefulShutdown()
      }
    }
  }

  func testGetListeningAddress_UnixDomainSocket() async throws {
    let transport = GRPCNIOTransportCore.HTTP2ServerTransport.TransportServices(
      address: .unixDomainSocket(path: "/tmp/niots-uds-test"),
      transportSecurity: .plaintext
    )
    defer {
      // NIOTS does not unlink the UDS on close.
      try? FileManager.default.removeItem(atPath: "/tmp/niots-uds-test")
    }

    try await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        try await transport.listen { _, _ in }
      }

      group.addTask {
        let address = try await transport.listeningAddress
        XCTAssertEqual(
          address.unixDomainSocket,
          GRPCNIOTransportCore.SocketAddress.UnixDomainSocket(path: "/tmp/niots-uds-test")
        )
        transport.beginGracefulShutdown()
      }
    }
  }

  func testGetListeningAddress_InvalidAddress() async {
    let transport = GRPCNIOTransportCore.HTTP2ServerTransport.TransportServices(
      address: .unixDomainSocket(path: "/this/should/be/an/invalid/path"),
      transportSecurity: .plaintext
    )

    try? await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        try await transport.listen { _, _ in }
      }

      group.addTask {
        do {
          _ = try await transport.listeningAddress
          XCTFail("Should have thrown a RuntimeError")
        } catch let error as RuntimeError {
          XCTAssertEqual(error.code, .serverIsStopped)
          XCTAssertEqual(
            error.message,
            """
            There is no listening address bound for this server: there may have \
            been an error which caused the transport to close, or it may have shut down.
            """
          )
        }
      }
    }
  }

  func testGetListeningAddress_StoppedListening() async throws {
    let transport = GRPCNIOTransportCore.HTTP2ServerTransport.TransportServices(
      address: .ipv4(host: "0.0.0.0", port: 0),
      transportSecurity: .plaintext
    )

    try? await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        try await transport.listen { _, _ in }

        do {
          _ = try await transport.listeningAddress
          XCTFail("Should have thrown a RuntimeError")
        } catch let error as RuntimeError {
          XCTAssertEqual(error.code, .serverIsStopped)
          XCTAssertEqual(
            error.message,
            """
            There is no listening address bound for this server: there may have \
            been an error which caused the transport to close, or it may have shut down.
            """
          )
        }
      }

      group.addTask {
        let address = try await transport.listeningAddress
        XCTAssertNotNil(address.ipv4)
        transport.beginGracefulShutdown()
      }
    }
  }

  @Sendable private static func loadIdentity() throws -> SecIdentity {
    let certificateKeyPairs = try SelfSignedCertificateKeyPairs()
    let password = "somepassword"
    let bundle = NIOSSLPKCS12Bundle(
      certificateChain: [
        try NIOSSLCertificate(bytes: certificateKeyPairs.server.certificate, format: .der)
      ],
      privateKey: try NIOSSLPrivateKey(bytes: certificateKeyPairs.server.key, format: .der)
    )
    let pkcs12Bytes = try bundle.serialize(passphrase: password.utf8)
    let options = [kSecImportExportPassphrase as String: password]
    var rawItems: CFArray?
    let status = SecPKCS12Import(
      Data(pkcs12Bytes) as CFData,
      options as CFDictionary,
      &rawItems
    )
    guard status == errSecSuccess else {
      XCTFail("Failed to import PKCS12 bundle: status \(status).")
      throw HTTP2TransportNIOTransportServicesTestsError.failedToImportPKCS12
    }
    let items = rawItems! as! [[String: Any]]
    let firstItem = items[0]
    let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity
    return identity
  }

  func testServerConfig_Defaults() throws {
    let grpcTLSConfig = HTTP2ServerTransport.TransportServices.TLS.defaults(
      identityProvider: Self.loadIdentity
    )
    let grpcConfig = HTTP2ServerTransport.TransportServices.Config.defaults

    XCTAssertEqual(grpcConfig.compression, HTTP2ServerTransport.Config.Compression.defaults)
    XCTAssertEqual(grpcConfig.connection, HTTP2ServerTransport.Config.Connection.defaults)
    XCTAssertEqual(grpcConfig.http2, HTTP2ServerTransport.Config.HTTP2.defaults)
    XCTAssertEqual(grpcConfig.rpc, HTTP2ServerTransport.Config.RPC.defaults)

    XCTAssertNotNil(grpcTLSConfig.identityProvider)
    XCTAssertEqual(grpcTLSConfig.trustRoots, .systemDefault)
    XCTAssertEqual(grpcTLSConfig.clientCertificateVerification, .noVerification)
    XCTAssertEqual(grpcTLSConfig.requireALPN, false)
  }

  func testClientConfig_Defaults() throws {
    let grpcTLSConfig = HTTP2ClientTransport.TransportServices.TLS.defaults
    let grpcConfig = HTTP2ClientTransport.TransportServices.Config.defaults

    XCTAssertEqual(grpcConfig.compression, HTTP2ClientTransport.Config.Compression.defaults)
    XCTAssertEqual(grpcConfig.connection, HTTP2ClientTransport.Config.Connection.defaults)
    XCTAssertEqual(grpcConfig.http2, HTTP2ClientTransport.Config.HTTP2.defaults)
    XCTAssertEqual(grpcConfig.backoff, HTTP2ClientTransport.Config.Backoff.defaults)

    XCTAssertNil(grpcTLSConfig.identityProvider)
    XCTAssertEqual(grpcTLSConfig.serverCertificateVerification, .fullVerification)
    XCTAssertEqual(grpcTLSConfig.trustRoots, .systemDefault)
  }
}

enum HTTP2TransportNIOTransportServicesTestsError: Error {
  case failedToImportPKCS12
}
#endif
