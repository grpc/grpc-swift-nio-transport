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
///
/// ## Update modes
///
/// Resolvers may be **push-based** or **pull-based**:
///
/// - **Push-based resolvers** (``UpdateMode-swift.struct/push``): Addresses are pushed to the
///   resolver by an external source (e.g., file watcher, service discovery subscription). The
///   channel subscribes to changes by awaiting new values in a loop.
///
/// - **Pull-based resolvers** (``UpdateMode-swift.struct/pull``): Addresses are resolved on-demand.
///   The channel requests new results as and when needed (e.g., after receiving a `GOAWAY` from
///   the server) by calling `next()`. Each `next()` call should attempt resolution.
///
/// ## Resolver semantics
///
/// Resolvers must follow these semantics for correct behavior.
///
/// ### Returning endpoints
///
/// Return a ``NameResolutionResult`` with a non-empty `endpoints` array when resolution succeeds.
/// The channel will create or update its load balancer with the new endpoints.
///
/// - **Push-based resolvers** should push updates whenever the endpoint list changes.
///
/// - **Pull-based resolvers** should return the current endpoint list each time `next()` is called.
///
/// ### Error handling
///
/// When resolution fails (e.g., DNS timeout, network unreachable, service discovery unavailable),
/// resolvers may throw an error. If the resolver throws errors then it **must** be
/// **re-iterable**: calling `makeAsyncIterator()` multiple times must return independent iterators
/// that can each attempt resolution.
///
/// After an iterator throws, the channel will:
/// - Keep using the last known good endpoints (if any exist)
/// - Wait (with exponential backoff)
/// - Create a new iterator by calling `makeAsyncIterator()` and retry
/// - New RPCs will be failed when the next resolution attempt fails (unless `waitForReady`
///   is `true`)
///
/// ### Empty endpoint lists
///
/// Returning a ``NameResolutionResult`` with an empty `endpoints` array indicates that
/// resolution succeeded but no backends are currently available. The channel will:
/// - Ignore the empty result and keep using last known good endpoints (if possible)
/// - Continue listening for the next update (but will not actively retry)
///
/// Returning an empty endpoint list is discouraged. Throwing an error is preferred as it will trigger
/// a retry and the channel will eventually recover.
///
/// ### Sequence completion
///
/// When an iterator completes (returns `nil`), the channel treats this the same as an error:
/// it will wait with exponential backoff and create a new iterator by calling
/// `makeAsyncIterator()` again.
///
/// - **Push-based resolvers**: If the external source closes the subscription cleanly
///   (e.g., service discovery server restart, watch stream closes), the iterator may return nil.
///   The channel will re-establish a fresh subscription by creating a new iterator.
///
/// - **Pull-based resolvers**: Should not return nil. Each `next()` call should either return
///   a result or throw an error.
///
/// The channel stops consuming from the resolver when shutting down. For **push-based** resolvers,
/// the channel will cancel the task iterating the resolver. When an iterator throws a
/// `CancellationError`, the channel will **not** create a new iterator (as shutdown is in
/// progress).
///
/// ## Resolver Patterns
///
/// ### Push based
///
/// **When to use**: Consuming subscription based external sources like service discovery.
///
/// - `makeAsyncIterator()`: Each call establishes a new subscription to the external source.
/// - `next()`: Yields updates from the subscription. Throws when the subscription fails.
///   May return `nil` when the source closes cleanly (e.g., server restart, connection closed).
/// - Error handling: Throw errors on subscription failure. Return nil on clean closure.
///   The channel will create a new iterator after exponential backoff in either case. Must
///   throw `CancellationError` when cancelled.
///
/// ### Pull based
///
/// **When to use**: Static addresses that never change or on-demand resolution (e.g., DNS lookup).
///
/// - `makeAsyncIterator()`: Each call returns a fresh, independent iterator.
/// - `next()`: Attempts resolution each time it's called. Throws on resolution failure
///   (e.g., DNS timeout, network unreachable).
/// - Error handling: Throw errors on resolution failure. The channel will create a new iterator
///   after exponential backoff.
@available(gRPCSwiftNIOTransport 2.0, *)
public struct NameResolver: Sendable {
  /// A sequence of name resolution results.
  ///
  /// See ``NameResolver`` for the expected behavior of this sequence, including update modes,
  /// error handling, empty endpoint lists, and sequence completion semantics.
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
public enum ResolvableTargets: Sendable {}

/// A namespace for name resolver factories.
@available(gRPCSwiftNIOTransport 2.0, *)
public enum NameResolvers: Sendable {}
