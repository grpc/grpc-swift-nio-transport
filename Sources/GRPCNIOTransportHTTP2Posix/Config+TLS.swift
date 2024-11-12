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

extension HTTP2ServerTransport.Posix.Config {
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
    /// The certificates the server will offer during negotiation.
    public var certificateChain: [TLSConfig.CertificateSource]

    /// The private key associated with the leaf certificate.
    public var privateKey: TLSConfig.PrivateKeySource

    /// How to verify the client certificate, if one is presented.
    public var clientCertificateVerification: TLSConfig.CertificateVerification

    /// The trust roots to be used when verifying client certificates.
    public var trustRoots: TLSConfig.TrustRootsSource

    /// Whether ALPN is required.
    ///
    /// If this is set to `true` but the client does not support ALPN, then the connection will be rejected.
    public var requireALPN: Bool

    /// Create a new HTTP2 NIO Posix server transport TLS config.
    /// - Parameters:
    ///   - certificateChain: The certificates the server will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - clientCertificateVerification: How to verify the client certificate, if one is presented.
    ///   - trustRoots: The trust roots to be used when verifying client certificates.
    ///   - requireALPN: Whether ALPN is required.
    public init(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      clientCertificateVerification: TLSConfig.CertificateVerification,
      trustRoots: TLSConfig.TrustRootsSource,
      requireALPN: Bool
    ) {
      self.certificateChain = certificateChain
      self.privateKey = privateKey
      self.clientCertificateVerification = clientCertificateVerification
      self.trustRoots = trustRoots
      self.requireALPN = requireALPN
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted:
    /// - `clientCertificateVerificationMode` equals `doNotVerify`
    /// - `trustRoots` equals `systemDefault`
    /// - `requireALPN` equals `false`
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the server will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func defaults(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        certificateChain: certificateChain,
        privateKey: privateKey,
        clientCertificateVerification: .noVerification,
        trustRoots: .systemDefault,
        requireALPN: false
      )
      configure(&config)
      return config
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted to match
    /// the requirements of mTLS:
    /// - `clientCertificateVerificationMode` equals `noHostnameVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `requireALPN` equals `false`
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the server will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func mTLS(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        certificateChain: certificateChain,
        privateKey: privateKey,
        clientCertificateVerification: .noHostnameVerification,
        trustRoots: .systemDefault,
        requireALPN: false
      )
      configure(&config)
      return config
    }
  }
}

extension HTTP2ClientTransport.Posix.Config {
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
    /// The certificates the client will offer during negotiation.
    public var certificateChain: [TLSConfig.CertificateSource]

    /// The private key associated with the leaf certificate.
    public var privateKey: TLSConfig.PrivateKeySource?

    /// How to verify the server certificate, if one is presented.
    public var serverCertificateVerification: TLSConfig.CertificateVerification

    /// The trust roots to be used when verifying server certificates.
    public var trustRoots: TLSConfig.TrustRootsSource

    /// An optional server hostname to use when verifying certificates.
    public var serverHostname: String?

    /// Create a new HTTP2 NIO Posix client transport TLS config.
    /// - Parameters:
    ///   - certificateChain: The certificates the client will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - serverCertificateVerification: How to verify the server certificate, if one is presented.
    ///   - trustRoots: The trust roots to be used when verifying server certificates.
    ///   - serverHostname: An optional server hostname to use when verifying certificates.
    public init(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource?,
      serverCertificateVerification: TLSConfig.CertificateVerification,
      trustRoots: TLSConfig.TrustRootsSource,
      serverHostname: String?
    ) {
      self.certificateChain = certificateChain
      self.privateKey = privateKey
      self.serverCertificateVerification = serverCertificateVerification
      self.trustRoots = trustRoots
      self.serverHostname = serverHostname
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted:
    /// - `certificateChain` equals `[]`
    /// - `privateKey` equals `nil`
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `serverHostname` equals `nil`
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func defaults(
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        certificateChain: [],
        privateKey: nil,
        serverCertificateVerification: .fullVerification,
        trustRoots: .systemDefault,
        serverHostname: nil
      )
      configure(&config)
      return config
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted:
    /// - `certificateChain` equals `[]`
    /// - `privateKey` equals `nil`
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    /// - `serverHostname` equals `nil`
    public static var defaults: Self { .defaults() }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted to match
    /// the requirements of mTLS:
    /// - `trustRoots` equals `systemDefault`
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `serverHostname` equals `nil`
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the client will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func mTLS(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout Self) -> Void = { _ in }
    ) -> Self {
      var config = Self(
        certificateChain: certificateChain,
        privateKey: privateKey,
        serverCertificateVerification: .fullVerification,
        trustRoots: .systemDefault,
        serverHostname: nil
      )
      configure(&config)
      return config
    }
  }
}
