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

private import GRPCCore

@available(gRPCSwiftNIOTransport 1.0, *)
extension ResolvableTargets {
  /// A resolvable target for addresses which can be resolved via DNS.
  ///
  /// If you already have an IPv4 or IPv6 address use ``ResolvableTargets/IPv4`` and
  /// ``ResolvableTargets/IPv6`` respectively.
  public struct DNS: ResolvableTarget, Sendable {
    /// The host to resolve via DNS.
    public var host: String

    /// The port to use with resolved addresses.
    ///
    /// If no port is specified then 443 is used.
    public var port: Int?

    /// Create a new DNS target.
    /// - Parameters:
    ///   - host: The host to resolve via DNS.
    ///   - port: The port to use with resolved addresses.
    public init(host: String, port: Int?) {
      self.host = host
      self.port = port
    }
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension ResolvableTarget where Self == ResolvableTargets.DNS {
  /// Creates a new resolvable DNS target.
  /// - Parameters:
  ///   - host: The host address to resolve.
  ///   - port: The port to use for each resolved address. 443 will be used if unspecified.
  /// - Returns: A ``ResolvableTarget``.
  public static func dns(host: String, port: Int? = nil) -> Self {
    return Self(host: host, port: port)
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension NameResolvers {
  /// A ``NameResolverFactory`` for ``ResolvableTargets/DNS`` targets.
  public struct DNS: NameResolverFactory {
    public typealias Target = ResolvableTargets.DNS

    /// Create a new DNS name resolver factory.
    public init() {}

    public func resolver(for target: Target) -> NameResolver {
      let resolver = Self.Resolver(target: target)
      // Only append the port if explicitly set. If it's nil the default port of 443 is used
      // should be omitted from the authority.
      let authority = target.host + (target.port.map { ":\($0)" } ?? "")
      return NameResolver(
        names: RPCAsyncSequence(wrapping: resolver),
        updateMode: .pull,
        authority: authority
      )
    }
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension NameResolvers.DNS {
  struct Resolver: Sendable {
    var target: ResolvableTargets.DNS

    init(target: ResolvableTargets.DNS) {
      self.target = target
    }

    func resolve(
      isolation actor: isolated (any Actor)? = nil
    ) async throws -> NameResolutionResult {
      let addresses: [SocketAddress]

      do {
        addresses = try await DNSResolver.resolve(
          host: self.target.host,
          port: self.target.port ?? 443  // Assume TLS if no port is specified.
        )
      } catch let error as CancellationError {
        throw error
      } catch {
        throw RPCError(
          code: .internalError,
          message: "Couldn't resolve address for \(self.target.host):\(self.target.port ?? 443)",
          cause: error
        )
      }

      return NameResolutionResult(endpoints: [Endpoint(addresses: addresses)], serviceConfig: nil)
    }
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension NameResolvers.DNS.Resolver: AsyncSequence {
  typealias Element = NameResolutionResult

  func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(resolver: self)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    typealias Element = NameResolutionResult

    private let resolver: NameResolvers.DNS.Resolver

    init(resolver: NameResolvers.DNS.Resolver) {
      self.resolver = resolver
    }

    func next() async throws -> NameResolutionResult? {
      return try await self.next(isolation: nil)
    }

    func next(
      isolation actor: isolated (any Actor)?
    ) async throws(any Error) -> NameResolutionResult? {
      return try await self.resolver.resolve(isolation: actor)
    }
  }
}
