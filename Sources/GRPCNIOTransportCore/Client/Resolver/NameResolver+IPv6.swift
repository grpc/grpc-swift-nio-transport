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
internal import NIOCore

@available(gRPCSwiftNIOTransport 2.0, *)
extension ResolvableTargets {
  /// A resolvable target for IPv4 addresses.
  ///
  /// IPv4 addresses can be resolved by the ``NameResolvers/IPv6`` resolver which creates a
  /// separate ``Endpoint`` for each address.
  public struct IPv6: ResolvableTarget, Sendable {
    /// The IPv6 addresses.
    public var addresses: [SocketAddress.IPv6]

    /// Create a new IPv6 target.
    /// - Parameter addresses: The IPv6 addresses.
    public init(addresses: [SocketAddress.IPv6]) {
      debugOnly {
        for address in addresses {
          do {
            switch try? NIOCore.SocketAddress(ipAddress: address.host, port: address.port) {
            case .v6:
              ()
            default:
              assertionFailure(
                """
                \(address.host):\(address.port) isn't a valid IPv6 address, did you mean to \
                use 'dns(host:port:)' instead?
                """
              )
            }
          }
        }
      }
      self.addresses = addresses
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ResolvableTarget where Self == ResolvableTargets.IPv6 {
  /// Creates a new resolvable IPv6 target for a single address.
  /// - Parameters:
  ///   - host: The resolved host address.
  ///   - port: The port on the host.
  /// - Returns: A ``ResolvableTarget``.
  @available(*, deprecated, renamed: "ipv6(address:port:)")
  public static func ipv6(host: String, port: Int = 443) -> Self {
    let address = SocketAddress.IPv6(host: host, port: port)
    return Self(addresses: [address])
  }

  /// Creates a new resolvable IPv6 target for a single address.
  /// - Parameters:
  ///   - address: The resolved host address.
  ///   - port: The port on the host.
  /// - Returns: A ``ResolvableTarget``.
  @available(gRPCSwiftNIOTransport 2.1, *)
  public static func ipv6(address: String, port: Int = 443) -> Self {
    let address = SocketAddress.IPv6(host: address, port: port)
    return Self(addresses: [address])
  }

  /// Creates a new resolvable IPv6 target from the provided host-port pairs.
  ///
  /// - Parameter pairs: An array of host-port pairs.
  /// - Returns: A ``ResolvableTarget``.
  public static func ipv6(pairs: [(host: String, port: Int)]) -> Self {
    let address = pairs.map { SocketAddress.IPv6(host: $0.host, port: $0.port) }
    return Self(addresses: address)
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NameResolvers {
  /// A ``NameResolverFactory`` for ``ResolvableTargets/IPv6`` targets.
  ///
  /// The name resolver for a given target always produces the same values, with one endpoint per
  /// address in the target. This resolver doesn't support fetching service configuration.
  public struct IPv6: NameResolverFactory, Sendable {
    public typealias Target = ResolvableTargets.IPv6

    /// Create a new IPv6 resolver factory.
    public init() {}

    public func resolver(for target: Target) -> NameResolver {
      let endpoints = target.addresses.map { Endpoint(addresses: [.ipv6($0)]) }
      let resolutionResult = NameResolutionResult(endpoints: endpoints, serviceConfig: nil)
      return NameResolver(names: .constant(resolutionResult), updateMode: .pull)
    }
  }
}
