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

public import GRPCCore

/// A name resolver can provide resolved addresses and service configuration values over time.
@available(gRPCSwiftNIOTransport 2.0, *)
public struct NameResolver: Sendable {
  /// A sequence of name resolution results.
  ///
  /// Resolvers may be push or pull based. Resolvers with the ``UpdateMode-swift.struct/push``
  /// update mode have addresses pushed to them by an external source and you should subscribe
  /// to changes in addresses by awaiting for new values in a loop.
  ///
  /// Resolvers with the ``UpdateMode-swift.struct/pull`` update mode shouldn't be subscribed to,
  /// instead you should create an iterator and ask for new results as and when necessary.
  public var names: RPCAsyncSequence<NameResolutionResult, any Error>

  /// How ``names`` is updated and should be consumed.
  public let updateMode: UpdateMode

  /// The authority of the service.
  public let authority: String?

  public struct UpdateMode: Hashable, Sendable {
    enum Value: Hashable, Sendable {
      case push
      case pull
    }

    let value: Value

    private init(_ value: Value) {
      self.value = value
    }

    /// Addresses are pushed to the resolve by an external source.
    public static var push: Self { Self(.push) }

    /// Addresses are resolved lazily, when the caller asks them to be resolved.
    public static var pull: Self { Self(.pull) }
  }

  /// Create a new name resolver.
  public init(
    names: RPCAsyncSequence<NameResolutionResult, any Error>,
    updateMode: UpdateMode,
    authority: String? = nil
  ) {
    self.names = names
    self.updateMode = updateMode
    self.authority = authority
  }
}

/// The result of name resolution, a list of endpoints to connect to and the service
/// configuration reported by the resolver.
@available(gRPCSwiftNIOTransport 2.0, *)
public struct NameResolutionResult: Hashable, Sendable {
  /// A list of endpoints to connect to.
  public var endpoints: [Endpoint]

  /// The service configuration reported by the resolver, or an error if it couldn't be parsed.
  /// This value may be `nil` if the resolver doesn't support fetching service configuration.
  public var serviceConfig: Result<ServiceConfig, RPCError>?

  public init(
    endpoints: [Endpoint],
    serviceConfig: Result<ServiceConfig, RPCError>?
  ) {
    self.endpoints = endpoints
    self.serviceConfig = serviceConfig
  }
}

/// A group of addresses which are considered equivalent when establishing a connection.
@available(gRPCSwiftNIOTransport 2.0, *)
public struct Endpoint: Hashable, Sendable {
  /// A list of equivalent addresses.
  ///
  /// Earlier addresses are typically but not always connected to first. Some load balancers may
  /// choose to ignore the order.
  public var addresses: [SocketAddress]

  /// Create a new ``Endpoint``.
  /// - Parameter addresses: A list of equivalent addresses.
  public init(addresses: [SocketAddress]) {
    self.addresses = addresses
  }
}

/// A resolver capable of resolving targets of type ``Target``.
@available(gRPCSwiftNIOTransport 2.0, *)
public protocol NameResolverFactory<Target> {
  /// The type of ``ResolvableTarget`` this factory makes resolvers for.
  associatedtype Target: ResolvableTarget

  /// Creates a resolver for the given target.
  ///
  /// - Parameter target: The target to make a resolver for.
  /// - Returns: The name resolver for the target.
  func resolver(for target: Target) -> NameResolver
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NameResolverFactory {
  /// Returns whether the given target is compatible with this factory.
  ///
  /// - Parameter target: The target to check the compatibility of.
  /// - Returns: Whether the target is compatible with this factory.
  func isCompatible<Other: ResolvableTarget>(withTarget target: Other) -> Bool {
    return target is Target
  }

  /// Returns a name resolver if the given target is compatible.
  ///
  /// - Parameter target: The target to make a name resolver for.
  /// - Returns: A name resolver or `nil` if the target isn't compatible.
  func makeResolverIfCompatible<Other: ResolvableTarget>(_ target: Other) -> NameResolver? {
    guard let target = target as? Target else { return nil }
    return self.resolver(for: target)
  }
}

/// A target which can be resolved to a ``SocketAddress``.
@available(gRPCSwiftNIOTransport 2.0, *)
public protocol ResolvableTarget {}

/// A namespace for resolvable targets.
@available(gRPCSwiftNIOTransport 2.0, *)
public enum ResolvableTargets {}

/// A namespace for name resolver factories.
@available(gRPCSwiftNIOTransport 2.0, *)
public enum NameResolvers {}
