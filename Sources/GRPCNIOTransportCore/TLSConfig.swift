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

@available(gRPCSwiftNIOTransport 2.0, *)
public enum TLSConfig: Sendable {
  /// The serialization format of the provided certificates and private keys.
  public struct SerializationFormat: Sendable, Equatable {
    package enum Wrapped {
      case pem
      case der
    }

    package let wrapped: Wrapped

    public static let pem = Self(wrapped: .pem)
    public static let der = Self(wrapped: .der)
  }

  /// A description of where a certificate is coming from: either a byte array or a file.
  /// The serialization format is specified by ``TLSConfig/SerializationFormat``.
  public struct CertificateSource: Sendable, Equatable {
    package enum Wrapped: Equatable {
      case file(path: String, format: SerializationFormat)
      case bytes(bytes: [UInt8], format: SerializationFormat)
      case transportSpecific(TransportSpecific)
    }

    package let wrapped: Wrapped

    /// The certificate's source is a file.
    /// - Parameters:
    ///   - path: The file path containing the certificate.
    ///   - format: The certificate's format, as a ``TLSConfig/SerializationFormat``.
    /// - Returns: A source describing the certificate source is the given file.
    public static func file(path: String, format: SerializationFormat) -> Self {
      Self(wrapped: .file(path: path, format: format))
    }

    /// The certificate's source is an array of bytes.
    /// - Parameters:
    ///   - bytes: The array of bytes making up the certificate.
    ///   - format: The certificate's format, as a ``TLSConfig/SerializationFormat``.
    /// - Returns: A source describing the certificate source is the given bytes.
    public static func bytes(_ bytes: [UInt8], format: SerializationFormat) -> Self {
      Self(wrapped: .bytes(bytes: bytes, format: format))
    }
  }

  /// A description of where the private key is coming from: either a byte array or a file.
  /// The serialization format is specified by ``TLSConfig/SerializationFormat``.
  public struct PrivateKeySource: Sendable {
    package enum Wrapped {
      case file(path: String, format: SerializationFormat)
      case bytes(bytes: [UInt8], format: SerializationFormat)
      case transportSpecific(any TransportSpecific)
    }

    package let wrapped: Wrapped

    /// The private key's source is a file.
    /// - Parameters:
    ///   - path: The file path containing the private key.
    ///   - format: The private key's format, as a ``TLSConfig/SerializationFormat``.
    /// - Returns: A source describing the private key source is the given file.
    public static func file(path: String, format: SerializationFormat) -> Self {
      Self(wrapped: .file(path: path, format: format))
    }

    /// The private key's source is an array of bytes.
    /// - Parameters:
    ///   - bytes: The array of bytes making up the private key.
    ///   - format: The private key's format, as a ``TLSConfig/SerializationFormat``.
    /// - Returns: A source describing the private key source is the given bytes.
    public static func bytes(
      _ bytes: [UInt8],
      format: SerializationFormat
    ) -> Self {
      Self(wrapped: .bytes(bytes: bytes, format: format))
    }
  }

  /// A description of where the trust roots are coming from: either a custom certificate chain, or the system default trust store.
  public struct TrustRootsSource: Sendable, Equatable {
    package enum Wrapped: Equatable {
      case certificates([CertificateSource])
      case systemDefault
    }

    package let wrapped: Wrapped

    /// A list of ``TLSConfig/CertificateSource``s making up the
    /// chain of trust.
    /// - Parameter certificateSources: The sources for the certificates that make up the chain of trust.
    /// - Returns: A trust root for the given chain of trust.
    public static func certificates(
      _ certificateSources: [CertificateSource]
    ) -> Self {
      Self(wrapped: .certificates(certificateSources))
    }

    /// The system default trust store.
    public static let systemDefault: Self = Self(wrapped: .systemDefault)
  }

  /// How to verify certificates.
  public struct CertificateVerification: Sendable, Equatable {
    package enum Wrapped: Equatable {
      case doNotVerify
      case fullVerification
      case noHostnameVerification
    }

    package let wrapped: Wrapped

    /// All certificate verification disabled.
    public static let noVerification: Self = Self(wrapped: .doNotVerify)

    /// Certificates will be validated against the trust store, but will not be checked to see if they are valid for the given hostname.
    public static let noHostnameVerification: Self = Self(wrapped: .noHostnameVerification)

    /// Certificates will be validated against the trust store and checked against the hostname of the service we are contacting.
    public static let fullVerification: Self = Self(wrapped: .fullVerification)
  }
}
