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

import Crypto
import Foundation
import SwiftASN1
import X509

/// Create a certificate chain with a root and intermediate certificate stored in a trust roots file and
/// key / certificate pairs for a client and a server. These can be used to establish mTLS connections
/// with local trust.
///
/// Usage example:
/// ```
/// // Create a new certificate chain
/// let certificateChain = try CertificateChain()
/// // Tag our certificate files with the function name
/// let filePaths = try certificateChain.writeToTemp(fileTag: #function)
/// // Access the file paths of the certificate files.
/// let clientCertPath = filePaths.clientCert
/// ...
/// ```
struct CertificateChain {
  /// Each node in the chain has a certificate and a key
  struct CertificateKeyPair {
    let certificate: Certificate
    let key: Certificate.PrivateKey
  }

  /// Leaf certificates can authenticate either a client or a server
  enum Authenticating {
    case client
    case server
  }

  /// Writing the files to disk returns the paths to all written files
  struct FilePaths {
    var clientCert: String
    var clientKey: String
    var serverCert: String
    var serverKey: String
    var trustRoots: String
  }

  /// The domains names for the leaf certificates
  static let serverName = "my.server"
  static let clientName = "my.client"

  /// Our certificate chain
  let root: CertificateKeyPair
  let intermediate: CertificateKeyPair
  let server: CertificateKeyPair
  let client: CertificateKeyPair

  /// On initialization create a chain of certificates: root signes intermediate, intermediate signs both leaf certificates
  init() throws {
    let root = try Self.makeRootCertificate(commonName: "root")
    let intermediate = try Self.makeIntermediateCertificate(
      commonName: "intermediate",
      signedBy: root
    )

    let server = try Self.makeLeafCertificate(
      commonName: "server",
      domainName: CertificateChain.serverName,
      authenticating: .server,
      signedBy: intermediate
    )
    let client = try Self.makeLeafCertificate(
      commonName: "client",
      domainName: CertificateChain.clientName,
      authenticating: .client,
      signedBy: intermediate
    )

    self.root = root
    self.intermediate = intermediate
    self.server = server
    self.client = client
  }

  /// Create a new root certificate.
  ///
  /// - Parameter commonName: CN of the certificate
  /// - Returns: A certificate and a private key.
  private static func makeRootCertificate(commonName cn: String) throws -> CertificateKeyPair {
    let privateKey = P256.Signing.PrivateKey()
    let key = Certificate.PrivateKey(privateKey)

    let subjectName = try DistinguishedName {
      CommonName(cn)
    }
    let issuerName = subjectName

    let now = Date()

    let extensions = try Certificate.Extensions {
      Critical(
        BasicConstraints.isCertificateAuthority(maxPathLength: nil)
      )
      Critical(
        KeyUsage(keyCertSign: true)
      )
    }

    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-1),
      notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 10),  // 10 years
      issuer: issuerName,
      subject: subjectName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: key
    )

    return CertificateKeyPair(certificate: certificate, key: key)
  }

  /// Create a new intermediate certificate.
  ///
  /// - Parameters:
  ///   - commonName: CN for the certificate
  ///   - signedBy: Certificate that signs this
  /// - Returns: A certificate and a private key.
  private static func makeIntermediateCertificate(
    commonName cn: String,
    signedBy issuer: CertificateKeyPair
  ) throws -> CertificateKeyPair {

    // Generate a new private key for the intermediate certificate
    let privateKey = P256.Signing.PrivateKey()
    let key = Certificate.PrivateKey(privateKey)

    // Create subject name for the intermediate certificate
    let subjectName = try DistinguishedName {
      CommonName(cn)
    }

    // Parse the root certificate to get the issuer information
    let issuerCert = issuer.certificate
    let issuerName = issuerCert.subject

    // Parse the root certificate's private key for signing
    let issuerKey = issuer.key

    let now = Date()

    // Configure extensions for intermediate CA
    let extensions = try Certificate.Extensions {
      Critical(
        BasicConstraints.isCertificateAuthority(
          maxPathLength: nil
        )
      )

      Critical(
        KeyUsage(keyCertSign: true, cRLSign: true)
      )

      // Add Authority Key Identifier linking to the root certificate
      try AuthorityKeyIdentifier(
        keyIdentifier: issuerCert.extensions.subjectKeyIdentifier?
          .keyIdentifier
      )
    }

    // Create the intermediate certificate
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-1),
      notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365),  // 1 year
      issuer: issuerName,
      subject: subjectName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: issuerKey
    )

    return CertificateKeyPair(
      certificate: certificate,
      key: key
    )
  }

  /// Create a new leaf certificate.
  ///
  /// - Parameters:
  ///   - commonName: CN for the certificate
  ///   - domainName: Domain name added as a SAN to the cert
  ///   - authenticating: Whether the certificate authenticates a client or a server
  ///   - signedBy: Certificate that signs this
  /// - Returns: A certificate and a private key.
  private static func makeLeafCertificate(
    commonName cn: String,
    domainName: String,
    authenticating side: Authenticating,
    signedBy issuer: CertificateKeyPair
  ) throws -> CertificateKeyPair {

    // Generate a new private key for the Leaf certificate
    let privateKey = P256.Signing.PrivateKey()
    let key = Certificate.PrivateKey(privateKey)

    // Create subject name for the Leaf certificate
    let subjectName = try DistinguishedName {
      CommonName(cn)
    }

    // Parse the root certificate to get the issuer information
    let issuerCert = issuer.certificate
    let issuerName = issuerCert.subject

    // Parse the root certificate's private key for signing
    let issuerKey = issuer.key

    let now = Date()

    // Configure extensions for Leaf CA
    let extensions = try Certificate.Extensions {
      BasicConstraints.notCertificateAuthority

      try ExtendedKeyUsage(
        side == .server ? [.serverAuth] : [.clientAuth]
      )

      SubjectAlternativeNames([.dnsName(domainName)])
    }

    // Create the Leaf certificate
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-1),
      notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 90),  // 90 days
      issuer: issuerName,
      subject: subjectName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: issuerKey
    )

    return CertificateKeyPair(
      certificate: certificate,
      key: key
    )
  }

  /// Write the certificate chain to a temporary directory.
  ///
  /// - Parameters:
  ///   - fileTag: A prefix added to all certificates files
  /// - Returns: A struct that contains paths of the written file
  public func writeToTemp(fileTag: String = #function) throws -> FilePaths {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory

    // Store file paths
    let trustRootsURL = directory.appendingPathComponent("\(fileTag).ca-chain.cert.pem")
    let clientCertURL = directory.appendingPathComponent("\(fileTag).client.cert.pem")
    let clientKeyURL = directory.appendingPathComponent("\(fileTag).client.key.pem")
    let serverCertURL = directory.appendingPathComponent("\(fileTag).server.cert.pem")
    let serverKeyURL = directory.appendingPathComponent("\(fileTag).server.key.pem")

    // Write chain: certificates of the root and intermediate in one file
    let rootPEM = try self.root.certificate.serializeAsPEM().pemString
    let intermediatePEM = try self.intermediate.certificate.serializeAsPEM().pemString
    try intermediatePEM.appending("\n").appending(rootPEM).write(
      to: trustRootsURL,
      atomically: true,
      encoding: .utf8
    )

    // Write leaf certificates and keys
    try self.client.writeKeyPair(certPath: clientCertURL, keyPath: clientKeyURL)
    try self.server.writeKeyPair(certPath: serverCertURL, keyPath: serverKeyURL)

    return FilePaths(
      clientCert: clientCertURL.path(),
      clientKey: clientKeyURL.path(),
      serverCert: serverCertURL.path(),
      serverKey: serverKeyURL.path(),
      trustRoots: trustRootsURL.path()
    )
  }
}

extension CertificateChain.CertificateKeyPair {
  fileprivate func writeKeyPair(certPath: URL, keyPath: URL) throws {
    try self.certificate.serializeAsPEM().pemString.write(
      to: certPath,
      atomically: true,
      encoding: .utf8
    )
    try self.key.serializeAsPEM().pemString.write(to: keyPath, atomically: true, encoding: .utf8)
  }
}
