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

internal import GRPCCore
internal import NIOSSL

extension NIOSSLSerializationFormats {
  fileprivate init(_ format: TLSConfig.SerializationFormat) {
    switch format.wrapped {
    case .pem:
      self = .pem
    case .der:
      self = .der
    }
  }
}

extension Sequence<TLSConfig.CertificateSource> {
  func sslCertificateSources() throws -> [NIOSSLCertificateSource] {
    var certificateSources: [NIOSSLCertificateSource] = []
    for source in self {
      switch source.wrapped {
      case .bytes(let bytes, let serializationFormat):
        switch serializationFormat.wrapped {
        case .der:
          certificateSources.append(
            .certificate(try NIOSSLCertificate(bytes: bytes, format: .der))
          )

        case .pem:
          let certificates = try NIOSSLCertificate.fromPEMBytes(bytes).map {
            NIOSSLCertificateSource.certificate($0)
          }
          certificateSources.append(contentsOf: certificates)
        }

      case .file(let path, let serializationFormat):
        switch serializationFormat.wrapped {
        case .der:
          certificateSources.append(
            .certificate(try NIOSSLCertificate(file: path, format: .der))
          )

        case .pem:
          let certificates = try NIOSSLCertificate.fromPEMFile(path).map {
            NIOSSLCertificateSource.certificate($0)
          }
          certificateSources.append(contentsOf: certificates)
        }
      }
    }
    return certificateSources
  }
}

extension TLSConfig.PrivateKeySource {
  enum _NIOSSLPrivateKeySource: TransportSpecific {
    case customPrivateKey(any (NIOSSLCustomPrivateKey & Hashable))
    case privateKey(NIOSSLPrivateKeySource)
  }

  static func nioSSLSpecific(_ source: _NIOSSLPrivateKeySource) -> Self {
    .transportSpecific(source)
  }
}

extension NIOSSLPrivateKey {
  fileprivate static func makePrivateKey(
    from source: TLSConfig.PrivateKeySource
  ) throws -> NIOSSLPrivateKey {
    switch source.wrapped {
    case .file(let path, let serializationFormat):
      return try self.init(
        file: path,
        format: NIOSSLSerializationFormats(serializationFormat)
      )

    case .bytes(let bytes, let serializationFormat):
      return try self.init(
        bytes: bytes,
        format: NIOSSLSerializationFormats(serializationFormat)
      )

    case .transportSpecific(let extraSource):
      guard let source = extraSource as? TLSConfig.PrivateKeySource._NIOSSLPrivateKeySource else {
        fatalError("Invalid private key source of type \(type(of: extraSource))")
      }

      switch source {
      case .customPrivateKey(let privateKey):
        return self.init(customPrivateKey: privateKey)

      case .privateKey(.privateKey(let key)):
        return key

      case .privateKey(.file(let path)):
        switch path.split(separator: ".").last {
        case "pem":
          return try NIOSSLPrivateKey(file: path, format: .pem)
        case "der", "key":
          return try NIOSSLPrivateKey(file: path, format: .der)
        default:
          throw RPCError(
            code: .invalidArgument,
            message: "Couldn't load private key from \(path)."
          )
        }
      }
    }
  }
}

extension NIOSSLTrustRoots {
  fileprivate init(_ trustRoots: TLSConfig.TrustRootsSource) throws {
    switch trustRoots.wrapped {
    case .certificates(let certificateSources):
      let certificates = try certificateSources.map { source in
        switch source.wrapped {
        case .bytes(let bytes, let serializationFormat):
          return try NIOSSLCertificate(
            bytes: bytes,
            format: NIOSSLSerializationFormats(serializationFormat)
          )
        case .file(let path, let serializationFormat):
          return try NIOSSLCertificate(
            file: path,
            format: NIOSSLSerializationFormats(serializationFormat)
          )
        }
      }
      self = .certificates(certificates)

    case .systemDefault:
      self = .default
    }
  }
}

extension CertificateVerification {
  fileprivate init(
    _ verificationMode: TLSConfig.CertificateVerification
  ) {
    switch verificationMode.wrapped {
    case .doNotVerify:
      self = .none
    case .fullVerification:
      self = .fullVerification
    case .noHostnameVerification:
      self = .noHostnameVerification
    }
  }
}

extension TLSConfiguration {
  package init(_ tlsConfig: HTTP2ServerTransport.Posix.TransportSecurity.TLS) throws {
    let certificateChain = try tlsConfig.certificateChain.sslCertificateSources()
    let privateKey = try NIOSSLPrivateKey.makePrivateKey(from: tlsConfig.privateKey)

    self = TLSConfiguration.makeServerConfiguration(
      certificateChain: certificateChain,
      privateKey: .privateKey(privateKey)
    )

    self.minimumTLSVersion = .tlsv12
    self.certificateVerification = CertificateVerification(tlsConfig.clientCertificateVerification)
    self.trustRoots = try NIOSSLTrustRoots(tlsConfig.trustRoots)
    self.applicationProtocols = ["grpc-exp", "h2"]
  }

  package init(_ tlsConfig: HTTP2ClientTransport.Posix.TransportSecurity.TLS) throws {
    self = TLSConfiguration.makeClientConfiguration()
    self.certificateChain = try tlsConfig.certificateChain.sslCertificateSources()

    if let privateKey = tlsConfig.privateKey {
      let privateKeySource = try NIOSSLPrivateKey.makePrivateKey(from: privateKey)
      self.privateKey = .privateKey(privateKeySource)
    }

    self.minimumTLSVersion = .tlsv12
    self.certificateVerification = CertificateVerification(tlsConfig.serverCertificateVerification)
    self.trustRoots = try NIOSSLTrustRoots(tlsConfig.trustRoots)
    self.applicationProtocols = ["grpc-exp", "h2"]
  }
}
