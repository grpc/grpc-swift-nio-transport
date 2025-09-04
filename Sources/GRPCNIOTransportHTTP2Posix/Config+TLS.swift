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

private import GRPCCore
public import NIOCertificateReloading
public import NIOSSL
public import NIO

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.Posix {
  /// The security configuration for this connection.
  public struct TransportSecurity: Sendable {
    package enum Wrapped: Sendable {
      case plaintext
      case tls(TLS)
    }

    package let wrapped: Wrapped

    /// This connection is plaintext: no encryption will take place.
    public static let plaintext = Self(wrapped: .plaintext)

    /// Secure connections with the given TLS configuration.
    public static func tls(_ tls: TLS) -> Self {
      Self(wrapped: .tls(tls))
    }

    /// Secure connections with TLS.
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the server will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func tls(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) -> Self {
      let tlsConfig: TLS = .defaults(
        certificateChain: certificateChain,
        privateKey: privateKey,
        configure: configure
      )
      return .tls(tlsConfig)
    }

    /// Create a new TLS config using a certificate reloader to provide the certificate chain
    /// and private key.
    ///
    /// The reloader must provide an initial certificate chain and private key. If you already
    /// have an initial certificate chain and private key you can use
    /// ``tls(certificateChain:privateKey:configure:)`` and set the certificate reloader via
    /// the `configure` callback.
    ///
    /// The defaults include setting:
    /// - `clientCertificateVerificationMode` to `doNotVerify`,
    /// - `trustRoots` to `systemDefault`, and
    /// - `requireALPN` to `false`.
    ///
    /// - Parameters:
    ///   - reloader: A certificate reloader which has been primed with an initial certificate chain
    ///       and private key.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Throws: If the reloader doesn't provide an initial certificate chain or private key.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func tls(
      certificateReloader reloader: any CertificateReloader,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) throws -> Self {
      let (certificateChain, privateKey) = try reloader.checkPrimed()
      return .tls(
        certificateChain: certificateChain.map { source in .nioSSLCertificateSource(source) },
        privateKey: .nioSSLSpecific(.privateKey(privateKey))
      ) { config in
        config.certificateReloader = reloader
        configure(&config)
      }
    }

    /// Secure the connection with mutual TLS.
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the client will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func mTLS(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) -> Self {
      let tlsConfig: TLS = .mTLS(
        certificateChain: certificateChain,
        privateKey: privateKey,
        configure: configure
      )
      return .tls(tlsConfig)
    }

    /// Create a new TLS config suitable for mTLS using a certificate reloader to provide the
    /// certificate chain and private key.
    ///
    /// The reloader must provide an initial certificate chain and private key. If you already
    /// have an initial certificate chain and private key you can use
    /// ``mTLS(certificateChain:privateKey:configure:)`` and set the certificate reloader via
    /// the `configure` callback.
    ///
    /// The defaults include setting:
    /// - `clientCertificateVerificationMode` to `noHostnameVerification`,
    /// - `trustRoots` to `systemDefault`, and
    /// - `requireALPN` to `false`.
    ///
    /// - Parameters:
    ///   - reloader: A certificate reloader which has been primed with an initial certificate chain
    ///       and private key.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Throws: If the reloader doesn't provide an initial certificate chain or private key.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func mTLS(
      certificateReloader reloader: any CertificateReloader,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) throws -> Self {
      let (certificateChain, privateKey) = try reloader.checkPrimed()
      return .mTLS(
        certificateChain: certificateChain.map { source in .nioSSLCertificateSource(source) },
        privateKey: .nioSSLSpecific(.privateKey(privateKey))
      ) { config in
        config.certificateReloader = reloader
        configure(&config)
      }
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.Posix.TransportSecurity {
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

    /// A certificate reloader providing the current certificate chain and private key to
    /// use at that point in time.
    public var certificateReloader: (any CertificateReloader)?

    /// Override the certificate verification with a custom callback that must return the verified certificate chain on success.
    /// Note: The callback is only used when `clientCertificateVerification` is *not* set to `noVerification`!
    public var customVerificationCallback:  (@Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResultWithMetadata>) -> Void)?

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

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.Posix {
  /// The security configuration for this connection.
  public struct TransportSecurity: Sendable {
    package enum Wrapped: Sendable {
      case plaintext
      case tls(TLS)
    }

    package let wrapped: Wrapped

    /// This connection is plaintext: no encryption will take place.
    public static let plaintext = Self(wrapped: .plaintext)

    /// Secure the connection with the given TLS configuration.
    public static func tls(_ tls: TLS) -> Self {
      Self(wrapped: .tls(tls))
    }

    /// Secure the connection with TLS using the default configuration.
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func tls(
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) -> Self {
      Self.tls(.defaults(configure: configure))
    }

    /// Secure the connection with TLS using the default configuration.
    public static var tls: Self {
      Self.tls(.defaults())
    }

    /// Secure the connection with mutual TLS.
    ///
    /// - Parameters:
    ///   - certificateChain: The certificates the client will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func mTLS(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) -> Self {
      let tlsConfig: TLS = .mTLS(
        certificateChain: certificateChain,
        privateKey: privateKey,
        configure: configure
      )
      return .tls(tlsConfig)
    }

    /// Create a new TLS config suitable for mTLS using a certificate reloader to provide the
    /// certificate chain and private key.
    ///
    /// The reloader must provide an initial certificate chain and private key. If you have already
    /// have an initial certificate chain and private key you can use
    /// ``mTLS(certificateChain:privateKey:configure:)`` and set the certificate reloader via
    /// the `configure` callback.
    ///
    /// The defaults include setting:
    /// - `trustRoots` to `systemDefault`, and
    /// - `serverCertificateVerification` to `fullVerification`.
    ///
    /// - Parameters:
    ///   - reloader: A certificate reloader which has been primed with an initial certificate chain
    ///       and private key.
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    /// - Throws: If the reloader doesn't provide an initial certificate chain or private key.
    /// - Returns: A new HTTP2 NIO Posix transport TLS config.
    public static func mTLS(
      certificateReloader reloader: any CertificateReloader,
      configure: (_ config: inout TLS) -> Void = { _ in }
    ) throws -> Self {
      let (certificateChain, privateKey) = try reloader.checkPrimed()
      return .mTLS(
        certificateChain: certificateChain.map { source in .nioSSLCertificateSource(source) },
        privateKey: .nioSSLSpecific(.privateKey(privateKey))
      ) { config in
        config.certificateReloader = reloader
        configure(&config)
      }
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.Posix.TransportSecurity {
  public struct TLS: Sendable {
    /// The certificates the client will offer during negotiation.
    public var certificateChain: [TLSConfig.CertificateSource]

    /// The private key associated with the leaf certificate.
    public var privateKey: TLSConfig.PrivateKeySource?

    /// How to verify the server certificate, if one is presented.
    public var serverCertificateVerification: TLSConfig.CertificateVerification

    /// The trust roots to be used when verifying server certificates.
    public var trustRoots: TLSConfig.TrustRootsSource

    /// A certificate reloader providing the current certificate chain and private key to
    /// use at that point in time.
    public var certificateReloader: (any CertificateReloader)?

    /// Create a new HTTP2 NIO Posix client transport TLS config.
    /// - Parameters:
    ///   - certificateChain: The certificates the client will offer during negotiation.
    ///   - privateKey: The private key associated with the leaf certificate.
    ///   - serverCertificateVerification: How to verify the server certificate, if one is presented.
    ///   - trustRoots: The trust roots to be used when verifying server certificates.
    public init(
      certificateChain: [TLSConfig.CertificateSource],
      privateKey: TLSConfig.PrivateKeySource?,
      serverCertificateVerification: TLSConfig.CertificateVerification,
      trustRoots: TLSConfig.TrustRootsSource
    ) {
      self.certificateChain = certificateChain
      self.privateKey = privateKey
      self.serverCertificateVerification = serverCertificateVerification
      self.trustRoots = trustRoots
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted:
    /// - `certificateChain` equals `[]`
    /// - `privateKey` equals `nil`
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
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
        trustRoots: .systemDefault
      )
      configure(&config)
      return config
    }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted:
    /// - `certificateChain` equals `[]`
    /// - `privateKey` equals `nil`
    /// - `serverCertificateVerification` equals `fullVerification`
    /// - `trustRoots` equals `systemDefault`
    public static var defaults: Self { .defaults() }

    /// Create a new HTTP2 NIO Posix transport TLS config, with some values defaulted to match
    /// the requirements of mTLS:
    /// - `trustRoots` equals `systemDefault`
    /// - `serverCertificateVerification` equals `fullVerification`
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
        trustRoots: .systemDefault
      )
      configure(&config)
      return config
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension TLSConfig.PrivateKeySource {
  /// Creates a key source from a `NIOSSLCustomPrivateKey`.
  ///
  /// This private key source is only applicable to the NIOPosix based transports. Using one
  /// with a NIOTransportServices based transport is a programmer error.
  ///
  /// - Parameter key: The custom private key.
  /// - Returns: A private key source wrapping the custom private key.
  public static func customPrivateKey(_ key: any (NIOSSLCustomPrivateKey & Hashable)) -> Self {
    .nioSSLSpecific(.customPrivateKey(key))
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension TLSConfig.CertificateSource {
  internal static func nioSSLCertificateSource(_ wrapped: NIOSSLCertificateSource) -> Self {
    return .transportSpecific(TransportSpecific(wrapped))
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension CertificateReloader {
  fileprivate func checkPrimed() throws -> ([NIOSSLCertificateSource], NIOSSLPrivateKeySource) {
    func explain(missingItem item: String) -> String {
      return """
        No \(item) available. The reloader must provide a certificate chain and private key when \
        creating a TLS config from a reloader. Ensure the reloader is ready or create a config \
        with a certificate chain and private key manually and set the certificate reloader \
        separately.
        """
    }

    let override = self.sslContextConfigurationOverride
    guard let certificateChain = override.certificateChain else {
      throw RPCError(code: .invalidArgument, message: explain(missingItem: "certificate chain"))
    }

    guard let privateKey = override.privateKey else {
      throw RPCError(code: .invalidArgument, message: explain(missingItem: "private key"))
    }

    return (certificateChain, privateKey)
  }
}
