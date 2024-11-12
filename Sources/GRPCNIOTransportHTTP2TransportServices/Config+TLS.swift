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
public import GRPCNIOTransportCore
public import Network

private import struct Foundation.Data
private import struct Foundation.URL

extension HTTP2ServerTransport.TransportServices.Config {
  /// The security configuration for this connection.
  public struct TransportSecurity: Sendable {
    package enum Wrapped: Sendable {
      case plaintext
      case tls(TLS)
    }

    package let wrapped: Wrapped

    /// This connection is plaintext: no encryption will take place.
    public static let plaintext = Self(wrapped: .plaintext)

    /// This connection will use TLS.
    public static func tls(_ tls: TLS) -> Self {
      Self(wrapped: .tls(tls))
    }
  }

  public struct TLS: Sendable {
    /// How to verify the client certificate, if one is presented.
    public var clientCertificateVerification: TLSConfig.CertificateVerification

    /// The trust roots to be used when verifying client certificates.
    public var trustRoots: TLSConfig.TrustRootsSource

    /// Whether ALPN is required.
    ///
    /// If this is set to `true` but the client does not support ALPN, then the connection will be rejected.
    public var requireALPN: Bool

    /// A provider for the `SecIdentity` to be used when setting up TLS.
    public var identityProvider: @Sendable () throws -> SecIdentity

    /// Create a new HTTP2 NIO Transport Services transport TLS config.
    /// - Parameters:
    ///   - clientCertificateVerification: How to verify the client certificate, if one is presented.
    ///   - trustRoots: The trust roots to be used when verifying client certificates.
    ///   - requireALPN: Whether ALPN is required.
    ///   - identityProvider: A provider for the `SecIdentity` to be used when setting up TLS.
    public init(
      clientCertificateVerification: TLSConfig.CertificateVerification,
      trustRoots: TLSConfig.TrustRootsSource,
      requireALPN: Bool,
      identityProvider: @Sendable @escaping () throws -> SecIdentity
    ) {
      self.clientCertificateVerification = clientCertificateVerification
      self.trustRoots = trustRoots
      self.requireALPN = requireALPN
      self.identityProvider = identityProvider
    }

    /// Create a new HTTP2 NIO Transport Services transport TLS config, with some values defaulted:
    /// - `clientCertificateVerificationMode` equals `doNotVerify`
    /// - `trustRoots` equals `systemDefault`
    /// - `requireALPN` equals `false`
    ///
    /// - Parameters:
    ///   - identityProvider: A provider for the `SecIdentity` to be used when setting up TLS.
    /// - Returns: A new HTTP2 NIO Transport Services transport TLS config.
    public static func defaults(
      identityProvider: @Sendable @escaping () throws -> SecIdentity,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        clientCertificateVerification: .noVerification,
        trustRoots: .systemDefault,
        requireALPN: false,
        identityProvider: identityProvider
      )
      configure(&config)
      return config
    }

    /// Create a new HTTP2 NIO Transport Services transport TLS config, with some values defaulted to match
    /// the requirements of mTLS:
    /// - `clientCertificateVerificationMode` equals `noHostnameVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `requireALPN` equals `false`
    ///
    /// - Parameters:
    ///   - identityProvider: A provider for the `SecIdentity` to be used when setting up TLS.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Transport Services transport TLS config.
    public static func mTLS(
      identityProvider: @Sendable @escaping () throws -> SecIdentity,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        clientCertificateVerification: .noHostnameVerification,
        trustRoots: .systemDefault,
        requireALPN: false,
        identityProvider: identityProvider
      )
      configure(&config)
      return config
    }
  }
}

extension HTTP2ClientTransport.TransportServices.Config {
  /// The security configuration for this connection.
  public struct TransportSecurity: Sendable {
    package enum Wrapped: Sendable {
      case plaintext
      case tls(TLS)
    }

    package let wrapped: Wrapped

    /// This connection is plaintext: no encryption will take place.
    public static let plaintext = Self(wrapped: .plaintext)

    /// This connection will use TLS.
    public static func tls(_ tls: TLS) -> Self {
      Self(wrapped: .tls(tls))
    }
  }

  public struct TLS: Sendable {
    /// How to verify the server certificate, if one is presented.
    public var serverCertificateVerification: TLSConfig.CertificateVerification

    /// The trust roots to be used when verifying server certificates.
    /// - Important: If specifying custom certificates, they must be DER-encoded X509 certificates.
    public var trustRoots: TLSConfig.TrustRootsSource

    /// An optional server hostname to use when verifying certificates.
    public var serverHostname: String?

    /// An optional provider for the `SecIdentity` to be used when setting up TLS.
    public var identityProvider: (@Sendable () throws -> SecIdentity)?

    /// Create a new HTTP2 NIO Transport Services transport TLS config.
    /// - Parameters:
    ///   - serverCertificateVerification: How to verify the server certificate, if one is presented.
    ///   - trustRoots: The trust roots to be used when verifying server certificates.
    ///   - serverHostname: An optional server hostname to use when verifying certificates.
    ///   - identityProvider: A provider for the `SecIdentity` to be used when setting up TLS.
    public init(
      serverCertificateVerification: TLSConfig.CertificateVerification,
      trustRoots: TLSConfig.TrustRootsSource,
      serverHostname: String?,
      identityProvider: (@Sendable () throws -> SecIdentity)?
    ) {
      self.serverCertificateVerification = serverCertificateVerification
      self.serverHostname = serverHostname
      self.trustRoots = trustRoots
      self.identityProvider = identityProvider
    }

    /// Create a new HTTP2 NIO Transport Services transport TLS config, with some values defaulted:
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `serverHostname` equals `nil`
    /// - `identityProvider` equals `nil`
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func defaults(
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        serverCertificateVerification: .fullVerification,
        trustRoots: .systemDefault,
        serverHostname: nil,
        identityProvider: nil
      )
      configure(&config)
      return config
    }

    /// Create a new HTTP2 NIO Transport Services transport TLS config, with some values defaulted:
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `serverHostname` equals `nil`
    /// - `identityProvider` equals `nil`
    public static var defaults: Self { .defaults() }

    /// Create a new HTTP2 NIO Transport Services transport TLS config, with some values defaulted to match
    /// the requirements of mTLS:
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `serverHostname` equals `nil`
    ///
    /// - Parameters:
    ///   - identityProvider: A provider for the `SecIdentity` to be used when setting up TLS.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func mTLS(
      identityProvider: @Sendable @escaping () throws -> SecIdentity,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        serverCertificateVerification: .fullVerification,
        trustRoots: .systemDefault,
        serverHostname: nil,
        identityProvider: identityProvider
      )
      configure(&config)
      return config
    }
  }
}

extension NWProtocolTLS.Options {
  func setUpVerifyBlock(trustRootsSource: TLSConfig.TrustRootsSource) {
    if let (verifyQueue, verifyBlock) = trustRootsSource.makeTrustRootsConfig() {
      sec_protocol_options_set_verify_block(
        self.securityProtocolOptions,
        verifyBlock,
        verifyQueue
      )
    }
  }
}

extension TLSConfig.TrustRootsSource {
  internal func makeTrustRootsConfig() -> (DispatchQueue, sec_protocol_verify_t)? {
    switch self.wrapped {
    case .certificates(let certificates):
      let verifyQueue = DispatchQueue(label: "io.grpc.CertificateVerification")
      let verifyBlock: sec_protocol_verify_t = { (metadata, trust, verifyCompleteCallback) in
        let actualTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        let customAnchors: [SecCertificate]
        do {
          customAnchors = try certificates.map { certificateSource in
            let certificateBytes: Data
            switch certificateSource.wrapped {
            case .file(let path, .der):
              certificateBytes = try Data(contentsOf: URL(filePath: path))

            case .bytes(let bytes, .der):
              certificateBytes = Data(bytes)

            case .file(_, let format), .bytes(_, let format):
              fatalError("Certificate format must be DER, but was \(format).")
            }

            guard let certificate = SecCertificateCreateWithData(nil, certificateBytes as CFData)
            else {
              fatalError("Certificate was not a valid DER-encoded X509 certificate.")
            }
            return certificate
          }
        } catch {
          verifyCompleteCallback(false)
          return
        }

        SecTrustSetAnchorCertificates(actualTrust, customAnchors as CFArray)
        SecTrustEvaluateAsyncWithError(actualTrust, verifyQueue) { _, trusted, _ in
          verifyCompleteCallback(trusted)
        }
      }

      return (verifyQueue, verifyBlock)

    case .systemDefault:
      return nil
    }
  }
}
#endif
