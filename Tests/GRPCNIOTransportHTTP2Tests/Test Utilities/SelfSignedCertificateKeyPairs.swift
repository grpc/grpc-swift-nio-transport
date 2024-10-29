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

import SwiftASN1
import X509
import Crypto
import Foundation

struct SelfSignedCertificateKeyPairs {
  struct CertificateKeyPair {
    let certificate: [UInt8]
    let key: [UInt8]
  }

  let server: CertificateKeyPair
  let client: CertificateKeyPair

  init() throws {
    let server = try Self.makeSelfSignedDERCertificateAndPrivateKey(name: "Server Certificate")
    let client = try Self.makeSelfSignedDERCertificateAndPrivateKey(name: "Client Certificate")

    self.server = CertificateKeyPair(certificate: server.cert, key: server.key)
    self.client = CertificateKeyPair(certificate: client.cert, key: client.key)
  }

  private static func makeSelfSignedDERCertificateAndPrivateKey(
    name: String
  ) throws -> (cert: [UInt8], key: [UInt8]) {
    let swiftCryptoKey = P256.Signing.PrivateKey()
    let key = Certificate.PrivateKey(swiftCryptoKey)
    let subjectName = try DistinguishedName { CommonName(name) }
    let issuerName = subjectName
    let now = Date()
    let extensions = try Certificate.Extensions {
      Critical(
        BasicConstraints.isCertificateAuthority(maxPathLength: nil)
      )
      Critical(
        KeyUsage(digitalSignature: true, keyCertSign: true)
      )
      Critical(
        try ExtendedKeyUsage([.serverAuth, .clientAuth])
      )
      SubjectAlternativeNames([.dnsName("localhost")])
    }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-60 * 60),
      notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365),
      issuer: issuerName,
      subject: subjectName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: key
    )

    var serializer = DER.Serializer()
    try serializer.serialize(certificate)

    let certBytes = serializer.serializedBytes
    let keyBytes = try key.serializeAsPEM().derBytes
    return (certBytes, keyBytes)
  }
}
