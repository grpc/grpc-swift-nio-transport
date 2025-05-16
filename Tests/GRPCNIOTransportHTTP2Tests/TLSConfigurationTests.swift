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

import GRPCNIOTransportHTTP2
import NIOCore
import NIOSSL
import Testing

struct TLSConfigurationTests {
  struct NoOpCustomPrivateKey: NIOSSLCustomPrivateKey, Hashable {
    var signatureAlgorithms: [SignatureAlgorithm] { [] }

    func sign(
      channel: any Channel,
      algorithm: SignatureAlgorithm,
      data: ByteBuffer
    ) -> EventLoopFuture<ByteBuffer> {
      channel.eventLoop.makeSucceededFuture(ByteBuffer())
    }

    func decrypt(channel: any Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
      channel.eventLoop.makeSucceededFuture(ByteBuffer())
    }
  }

  @Test("Client custom private key")
  func clientTLSCustomPrivateKey() throws {
    let custom = NoOpCustomPrivateKey()
    let config = HTTP2ClientTransport.Posix.TransportSecurity.tls {
      $0.privateKey = .customPrivateKey(custom)
    }

    let tls = try #require(config.tls)
    let tlsConfig = try TLSConfiguration(tls)
    let privateKey = try #require(tlsConfig.privateKey?.privateKey)
    #expect(privateKey == NIOSSLPrivateKey(customPrivateKey: custom))
  }

  @Test("Server custom private key")
  func serverTLSCustomPrivateKey() throws {
    let custom = NoOpCustomPrivateKey()
    let config = HTTP2ServerTransport.Posix.TransportSecurity.tls(
      certificateChain: [],
      privateKey: .customPrivateKey(custom)
    )

    let tls = try #require(config.tls)
    let tlsConfig = try TLSConfiguration(tls)
    let privateKey = try #require(tlsConfig.privateKey?.privateKey)
    #expect(privateKey == NIOSSLPrivateKey(customPrivateKey: custom))
  }
}

extension HTTP2ClientTransport.Posix.TransportSecurity {
  var tls: TLS? {
    switch self.wrapped {
    case .tls(let tls):
      return tls
    case .plaintext:
      return nil
    }
  }
}

extension HTTP2ServerTransport.Posix.TransportSecurity {
  var tls: TLS? {
    switch self.wrapped {
    case .tls(let tls):
      return tls
    case .plaintext:
      return nil
    }
  }
}

extension NIOSSLPrivateKeySource {
  var privateKey: NIOSSLPrivateKey? {
    switch self {
    case .privateKey(let key):
      return key
    case .file:
      return nil
    }
  }
}
