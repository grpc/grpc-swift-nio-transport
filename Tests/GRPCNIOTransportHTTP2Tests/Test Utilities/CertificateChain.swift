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

struct CertificateChain {
  struct CertificateKeyPair {
    let certificate: Certificate
    let key: Certificate.PrivateKey
  }

  enum Authenticating {
    case client
    case server
  }

  enum Files {
    case clientCert
    case clientKey
    case serverCert
    case serverKey
    case trustRoots
  }

  let serverName = "my.server"
  let clientName = "my.client"

  let root: CertificateKeyPair
  let intermediate: CertificateKeyPair
  let server: CertificateKeyPair
  let client: CertificateKeyPair

  init() throws {
    let root = try Self.makeRootCertificate(commonName: "root")
    let intermediate = try Self.makeIntermediateCertificate(
      commonName: "intermediate",
      signedBy: root
    )

    let server = try Self.makeLeafCertificate(
      commonName: "server",
      domainName: serverName,
      authenticating: .server,
      signedBy: intermediate
    )
    let client = try Self.makeLeafCertificate(
      commonName: "client",
      domainName: clientName,
      authenticating: .client,
      signedBy: intermediate
    )

    self.root = root
    self.intermediate = intermediate
    self.server = server
    self.client = client
  }

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

  private static func makeLeafCertificate(
    commonName cn: String,
    domainName: String,
    authenticating side: Authenticating,
    signedBy issuer: CertificateKeyPair,
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

  public func writeToTemp(fileTag: String) throws -> [Files: String] {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory

    var fileNames = [Files: String]()

    // File paths.
    let trustRootsPath = directory.appendingPathComponent("\(fileTag).ca-chain.cert.pem")
    fileNames[.trustRoots] = trustRootsPath.path()

    let clientCertPath = directory.appendingPathComponent("\(fileTag).client.cert.pem")
    fileNames[.clientCert] = clientCertPath.path()
    let clientKeyPath = directory.appendingPathComponent("\(fileTag).client.key.pem")
    fileNames[.clientKey] = clientKeyPath.path()

    let serverCertPath = directory.appendingPathComponent("\(fileTag).server.cert.pem")
    fileNames[.serverCert] = serverCertPath.path()

    let serverKeyPath = directory.appendingPathComponent("\(fileTag).server.key.pem")
    fileNames[.serverKey] = serverKeyPath.path()

    // Write chain: certificates of the root and intermediate in one file
    let rootPEM = try self.root.certificate.serializeAsPEM().pemString
    let intermediatePEM = try self.intermediate.certificate.serializeAsPEM().pemString

    try intermediatePEM.appending("\n").appending(rootPEM).write(
      to: trustRootsPath,
      atomically: true,
      encoding: .utf8
    )

    // Write leaf certificates
    try self.client.writeKeyPair(certPath: clientCertPath, keyPath: clientKeyPath)
    try self.server.writeKeyPair(certPath: serverCertPath, keyPath: serverKeyPath)

    return fileNames
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
