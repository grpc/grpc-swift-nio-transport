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

extension NIOAsyncChannel {
  var remoteAddressInfo: String {
    guard let remote = self.channel.remoteAddress else {
      return "<unknown>"
    }

    switch remote {
    case .v4(let address):
      // '!' is safe, v4 always has a port.
      return "ipv4:\(address.host):\(remote.port!)"

    case .v6(let address):
      // '!' is safe, v6 always has a port.
      return "ipv6:[\(address.host)]:\(remote.port!)"

    case .unixDomainSocket:
      // The pathname will be on the local address.
      guard let local = self.channel.localAddress else {
        // UDS but no local address; this shouldn't ever happen but at least note the transport
        // as being UDS.
        return "unix:<unknown>"
      }

      switch local {
      case .unixDomainSocket:
        // '!' is safe, UDS always has a path.
        return "unix:\(local.pathname!)"

      case .v4, .v6:
        // Remote address is UDS but local isn't. This shouldn't ever happen.
        return "unix:<unknown>"
      }
    }
  }

  var localAddressInfo: String {
    guard let local = self.channel.localAddress else {
      return "<unknown>"
    }

    switch local {
    case .v4(let address):
      // '!' is safe, v4 always has a port.
      return "ipv4:\(address.host):\(local.port!)"

    case .v6(let address):
      // '!' is safe, v6 always has a port.
      return "ipv6:[\(address.host)]:\(local.port!)"

    case .unixDomainSocket:
      // '!' is safe, UDS always has a path.
      return "unix:\(local.pathname!)"
    }
  }
}
