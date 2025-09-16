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

internal import NIOSSL
internal import SwiftASN1
internal import X509

@available(gRPCSwiftNIOTransport 2.2, *)
extension X509.ValidatedCertificateChain {
  // The precondition holds because the `NIOSSL.ValidatedCertificateChain` always contains one `NIOSSLCertificate`.
  init(_ chain: NIOSSL.ValidatedCertificateChain) throws {
    let certs = try chain.map {
      let derBytes = try $0.toDERBytes()
      return try Certificate(derEncoded: derBytes)
    }
    self.init(uncheckedCertificateChain: certs)
  }
}
