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

internal import NIOCore

@available(gRPCSwiftNIOTransport 1.0, *)
extension Channel {
  var remoteAddressInfo: String {
    self.getAddressInfoWithFallbackIfUDS(
      address: self.remoteAddress,
      udsFallback: self.localAddress
    )
  }

  var localAddressInfo: String {
    self.getAddressInfoWithFallbackIfUDS(
      address: self.localAddress,
      udsFallback: self.remoteAddress
    )
  }

  private func getAddressInfoWithFallbackIfUDS(
    address: NIOCore.SocketAddress?,
    udsFallback: NIOCore.SocketAddress?
  ) -> String {
    guard let address else {
      return "<unknown>"
    }

    switch address {
    case .v4(let ipv4Address):
      // '!' is safe, v4 always has a port.
      return "ipv4:\(ipv4Address.host):\(address.port!)"

    case .v6(let ipv6Address):
      // '!' is safe, v6 always has a port.
      return "ipv6:[\(ipv6Address.host)]:\(address.port!)"

    case .unixDomainSocket:
      // '!' is safe, UDS always has a path.
      if address.pathname!.isEmpty {
        guard let udsFallback else {
          return "unix:<unknown>"
        }

        switch udsFallback {
        case .unixDomainSocket:
          // '!' is safe, UDS always has a path.
          return "unix:\(udsFallback.pathname!)"

        case .v4, .v6:
          // Remote address is UDS but local isn't. This shouldn't ever happen.
          return "unix:<unknown>"
        }
      } else {
        // '!' is safe, UDS always has a path.
        return "unix:\(address.pathname!)"
      }
    }
  }
}
