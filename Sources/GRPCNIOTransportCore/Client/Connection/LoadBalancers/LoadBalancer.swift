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

@available(gRPCSwiftNIOTransport 2.0, *)
package enum LoadBalancer: Sendable {
  case roundRobin(RoundRobinLoadBalancer)
  case pickFirst(PickFirstLoadBalancer)
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension LoadBalancer {
  package init(_ loadBalancer: RoundRobinLoadBalancer) {
    self = .roundRobin(loadBalancer)
  }

  var id: LoadBalancerID {
    switch self {
    case .roundRobin(let loadBalancer):
      return loadBalancer.id
    case .pickFirst(let loadBalancer):
      return loadBalancer.id
    }
  }

  package var events: AsyncStream<LoadBalancerEvent> {
    switch self {
    case .roundRobin(let loadBalancer):
      return loadBalancer.events
    case .pickFirst(let loadBalancer):
      return loadBalancer.events
    }
  }

  package func run() async {
    switch self {
    case .roundRobin(let loadBalancer):
      await loadBalancer.run()
    case .pickFirst(let loadBalancer):
      await loadBalancer.run()
    }
  }

  package func close() {
    switch self {
    case .roundRobin(let loadBalancer):
      loadBalancer.close()
    case .pickFirst(let loadBalancer):
      loadBalancer.close()
    }
  }

  package func pickSubchannel() -> Subchannel? {
    switch self {
    case .roundRobin(let loadBalancer):
      return loadBalancer.pickSubchannel()
    case .pickFirst(let loadBalancer):
      return loadBalancer.pickSubchannel()
    }
  }
}

/// A key for an endpoint which identifies it uniquely, regardless of the ordering of addresses.
///
/// Load balancers use this to decide whether an endpoint they've been given is the one they
/// already have.
@available(gRPCSwiftNIOTransport 2.0, *)
struct EndpointKey: Hashable, Sendable, CustomStringConvertible {
  /// Opaque data.
  private let opaque: [String]

  /// The endpoint this key is for.
  let endpoint: Endpoint

  init(_ endpoint: Endpoint) {
    self.endpoint = endpoint
    self.opaque = endpoint.addresses.map { String(describing: $0) }.sorted()
  }

  var description: String {
    String(describing: self.endpoint.addresses)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(self.opaque)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.opaque == rhs.opaque
  }
}
