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

@available(gRPCSwiftNIOTransport 1.2, *)
extension TLSConfig.PrivateKeySource {
  /// Marker protocol for transport specific private key sources.
  ///
  /// `TLSConfig.PrivateKeySource` is from the core module which means it can't take a NIOSSL
  /// or NIOTransportServices dependency. In order to support more sources this transport-specific
  /// protocol is provided as non-public API.
  package protocol TransportSpecific: Sendable {}

  package static func transportSpecific(_ source: any TransportSpecific) -> Self {
    Self(wrapped: .transportSpecific(source))
  }
}

@available(gRPCSwiftNIOTransport 1.2, *)
extension TLSConfig.CertificateSource {
  /// A type-erased transport specific certificate source.
  ///
  /// `TLSConfig.CertificateSource` is from the core module which means it can't take a NIOSSL
  /// or NIOTransportServices dependency. In order to support more sources a transport-specific
  /// erased source is provided as non-public API.
  package struct TransportSpecific: Sendable, Equatable {
    package var wrapped: any Sendable
    private let isEqualTo: @Sendable (TransportSpecific) -> Bool

    package init<Value: Sendable & Equatable>(_ wrapped: Value) {
      self.wrapped = wrapped
      self.isEqualTo = { other in
        if let otherValue = other.wrapped as? Value {
          return otherValue == wrapped
        } else {
          return false
        }
      }
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.isEqualTo(rhs)
    }
  }

  package static func transportSpecific(_ value: TransportSpecific) -> Self {
    return Self(wrapped: .transportSpecific(value))
  }
}
