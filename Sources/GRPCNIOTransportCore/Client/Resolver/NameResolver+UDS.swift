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

@available(gRPCSwiftNIOTransport 1.0, *)
extension ResolvableTargets {
  /// A resolvable target for Unix Domain Socket address.
  ///
  /// ``UnixDomainSocket`` addresses can be resolved by the ``NameResolvers/UnixDomainSocket``
  /// resolver which creates a single ``Endpoint`` for target address.
  public struct UnixDomainSocket: ResolvableTarget {
    /// The Unix Domain Socket address.
    public var address: SocketAddress.UnixDomainSocket

    /// The authority of the service.
    ///
    /// If unset then the path of the address will be used.
    public var authority: String?

    /// Create a new Unix Domain Socket address.
    public init(address: SocketAddress.UnixDomainSocket, authority: String?) {
      self.address = address
      self.authority = authority
    }
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension ResolvableTarget where Self == ResolvableTargets.UnixDomainSocket {
  /// Creates a new resolvable Unix Domain Socket target.
  /// - Parameters
  ///   - path: The path of the socket.
  ///   - authority: The service authority.
  public static func unixDomainSocket(
    path: String,
    authority: String? = nil
  ) -> Self {
    return Self(
      address: SocketAddress.UnixDomainSocket(path: path),
      authority: authority
    )
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension NameResolvers {
  /// A ``NameResolverFactory`` for ``ResolvableTargets/UnixDomainSocket`` targets.
  ///
  /// The name resolver for a given target always produces the same values, with a single endpoint.
  /// This resolver doesn't support fetching service configuration.
  public struct UnixDomainSocket: NameResolverFactory {
    public typealias Target = ResolvableTargets.UnixDomainSocket

    public init() {}

    public func resolver(for target: Target) -> NameResolver {
      let endpoint = Endpoint(addresses: [.unixDomainSocket(target.address)])
      let resolutionResult = NameResolutionResult(endpoints: [endpoint], serviceConfig: nil)
      return NameResolver(
        names: .constant(resolutionResult),
        updateMode: .pull,
        authority: target.authority ?? target.address.path
      )
    }
  }
}
