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

import GRPCCore
import GRPCNIOTransportCore
import NIOCore
import NIOHTTP2
import NIOPosix
import XCTest

@available(gRPCSwiftNIOTransport 2.0, *)
final class PickFirstLoadBalancerTests: XCTestCase {
  func testPickFirstConnectsToServer() async throws {
    try await LoadBalancerTest.pickFirst(servers: 1, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: context.servers.map { $0.address })
        context.pickFirst!.updateEndpoint(endpoint)
      case .connectivityStateChanged(.ready):
        context.loadBalancer.close()
      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testPickSubchannelWhenNotReady() async throws {
    try await LoadBalancerTest.pickFirst(servers: 1, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        XCTAssertNil(context.loadBalancer.pickSubchannel())
        context.loadBalancer.close()
      case .connectivityStateChanged(.shutdown):
        XCTAssertNil(context.loadBalancer.pickSubchannel())
      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testPickSubchannelReturnsSameSubchannel() async throws {
    try await LoadBalancerTest.pickFirst(servers: 1, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: context.servers.map { $0.address })
        context.pickFirst!.updateEndpoint(endpoint)

      case .connectivityStateChanged(.ready):
        var ids = Set<SubchannelID>()
        for _ in 0 ..< 100 {
          let subchannel = try XCTUnwrap(context.loadBalancer.pickSubchannel())
          ids.insert(subchannel.id)
        }
        XCTAssertEqual(ids.count, 1)
        context.loadBalancer.close()

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testEndpointUpdateHandledGracefully() async throws {
    try await LoadBalancerTest.pickFirst(servers: 3, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: [context.servers[0].address])
        context.pickFirst!.updateEndpoint(endpoint)

      case .connectivityStateChanged(.ready):
        // Must be connected to server-0.
        try await XCTPoll(every: .milliseconds(10)) {
          context.servers[0].server.clients.count == 1
        }

        // Update the endpoint so that it contains server-1.
        let endpoint1 = Endpoint(addresses: [context.servers[1].address])
        context.pickFirst!.updateEndpoint(endpoint1)

        // Should remain in the ready state
        try await XCTPoll(every: .milliseconds(10)) {
          context.servers[0].server.clients.isEmpty && context.servers[1].server.clients.count == 1
        }

        // Update the endpoint so that it contains server-2.
        let endpoint2 = Endpoint(addresses: [context.servers[2].address])
        context.pickFirst!.updateEndpoint(endpoint2)

        // Should remain in the ready state
        try await XCTPoll(every: .milliseconds(10)) {
          context.servers[0].server.clients.isEmpty
            && context.servers[1].server.clients.isEmpty
            && context.servers[2].server.clients.count == 1
        }

        context.loadBalancer.close()

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testSameEndpointUpdateIsIgnored() async throws {
    try await LoadBalancerTest.pickFirst(servers: 1, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: context.servers.map { $0.address })
        context.pickFirst!.updateEndpoint(endpoint)

      case .connectivityStateChanged(.ready):
        // Must be connected to server-0.
        try await XCTPoll(every: .milliseconds(10)) {
          context.servers[0].server.clients.count == 1
        }
        let subchannel = try XCTUnwrap(context.loadBalancer.pickSubchannel())

        // Update the endpoint. This should be a no-op: the load balancer must keep its subchannel
        // rather than replace it, which would open (and promote) a second connection.
        let endpoint = Endpoint(addresses: context.servers.map { $0.address })
        context.pickFirst!.updateEndpoint(endpoint)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(context.servers[0].server.acceptedConnections, 1)
        XCTAssertEqual(context.servers[0].server.clients.count, 1)
        XCTAssertTrue(context.loadBalancer.pickSubchannel() === subchannel)

        context.loadBalancer.close()

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testSameEndpointInDifferentOrderUpdateIsIgnored() async throws {
    // Resolvers (e.g. DNS) may return the same addresses in a different order each time they're
    // asked, that isn't a change to the endpoint.
    try await LoadBalancerTest.pickFirst(servers: 2, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: context.servers.map { $0.address })
        context.pickFirst!.updateEndpoint(endpoint)

      case .connectivityStateChanged(.ready):
        // The first address is server-0, it's the only one which should be connected to.
        try await XCTPoll(every: .milliseconds(10)) {
          context.servers[0].server.clients.count == 1
        }
        let subchannel = try XCTUnwrap(context.loadBalancer.pickSubchannel())

        // Reverse the addresses: a new subchannel would connect to server-1 first.
        let endpoint = Endpoint(addresses: context.servers.map { $0.address }.reversed())
        context.pickFirst!.updateEndpoint(endpoint)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(context.servers[0].server.acceptedConnections, 1)
        XCTAssertEqual(context.servers[0].server.clients.count, 1)
        XCTAssertEqual(context.servers[1].server.acceptedConnections, 0)
        XCTAssertTrue(context.loadBalancer.pickSubchannel() === subchannel)

        context.loadBalancer.close()

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testSameEndpointUpdatesWhileFailingToConnectDoNotBypassBackoff() async throws {
    // When no address can be connected to the load balancer asks for names to be re-resolved. If
    // the resolver keeps returning the same endpoint (e.g. a stale DNS record) the load balancer
    // must keep the subchannel which is backing off. Replacing it would reset its backoff, and
    // so loop between connecting, asking for names to be resolved and replacing the subchannel.
    let endpoint = Endpoint(addresses: [.unixDomainSocket(path: "not-listening")])
    let start = ContinuousClock.now
    let requests = AtomicCounter()
    let finished = AtomicCounter()

    try await LoadBalancerTest.pickFirst(
      servers: 0,
      connector: .posix(),
      backoff: .fixed(at: .milliseconds(100))
    ) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        context.pickFirst!.updateEndpoint(endpoint)

      case .requiresNameResolution:
        requests.increment()

        // Behave like a channel whose resolver returns the same endpoint each time.
        context.pickFirst!.updateEndpoint(endpoint)

        if ContinuousClock.now - start >= .seconds(1), finished.increment().oldValue == 0 {
          // One request per backoff period is expected (about ten), a loop would make thousands.
          XCTAssertGreaterThan(requests.value, 1)
          XCTAssertLessThanOrEqual(requests.value, 30)
          context.loadBalancer.close()
        }

      default:
        ()
      }
    }
  }

  func testSameEndpointUpdateReplacesSubchannelWhichIsGoingAway() async throws {
    // After a GOAWAY a subchannel can't be used for new streams but its connection stays open
    // until the streams on it finish. The load balancer asks for names to be re-resolved, and
    // when the resolver returns the same endpoint the load balancer must still replace the
    // subchannel, otherwise new RPCs can't be sent until the old streams have finished.
    let server = TestServer(eventLoopGroup: .singletonMultiThreadedEventLoopGroup)
    let address = try await server.bind()
    let endpoint = Endpoint(addresses: [address])

    let pickFirst = PickFirstLoadBalancer(
      connector: .posix(),
      authority: nil,
      backoff: .defaults,
      defaultCompression: .none,
      enabledCompression: .none
    )

    let streamsOpened = AtomicCounter()
    let nameResolutionRequests = AtomicCounter()

    await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await server.run(.echo)
      }

      group.addTask {
        await pickFirst.run()
      }

      group.addTask {
        for await event in pickFirst.events {
          if case .requiresNameResolution = event {
            nameResolutionRequests.increment()
          }
        }
      }

      do {
        pickFirst.updateEndpoint(endpoint)

        var picked: Subchannel?
        try await XCTPoll(every: .milliseconds(10)) {
          picked = pickFirst.pickSubchannel()
          return picked != nil
        }
        let original = try XCTUnwrap(picked)

        // Open a stream and keep it open so the connection can't close after the GOAWAY.
        group.addTask {
          let stream = try await original.makeStream(descriptor: .echoGet, options: .defaults)
          try await stream.execute { inbound, outbound in
            try await outbound.write(.metadata([:]))
            for try await part in inbound {
              if case .metadata = part {
                streamsOpened.increment()
              }
            }
          }
        }

        try await XCTPoll(every: .milliseconds(10)) {
          streamsOpened.value == 1
        }

        let goAway = HTTP2Frame(
          streamID: .rootStream,
          payload: .goAway(lastStreamID: 1, errorCode: .noError, opaqueData: nil)
        )
        try await XCTUnwrap(server.clients.first).writeAndFlush(goAway)

        // The load balancer asks for names to be re-resolved, the resolver returns the same
        // endpoint.
        try await XCTPoll(every: .milliseconds(10)) {
          nameResolutionRequests.value == 1
        }
        pickFirst.updateEndpoint(endpoint)

        // The load balancer connects again without waiting for the old connection to close.
        picked = nil
        try await XCTPoll(every: .milliseconds(10)) {
          picked = pickFirst.pickSubchannel()
          return picked != nil
        }
        let replacement = try XCTUnwrap(picked)
        XCTAssertTrue(replacement !== original)
        XCTAssertEqual(server.acceptedConnections, 2)
        XCTAssertEqual(server.clients.count, 2)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }

      group.cancelAll()
    }
  }

  func testEmptyEndpointUpdateIsIgnored() async throws {
    // Checks that an update using the empty endpoint is ignored.
    try await LoadBalancerTest.pickFirst(servers: 0, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let endpoint = Endpoint(addresses: [])
        // Should no-op.
        context.pickFirst!.updateEndpoint(endpoint)
        context.loadBalancer.close()

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testPickOnIdleTriggersConnect() async throws {
    // Tests that picking a subchannel when the load balancer is idle triggers a reconnect and
    // becomes ready again. Uses a very short idle time to re-enter the idle state.
    let idle = AtomicCounter()

    try await LoadBalancerTest.pickFirst(
      servers: 1,
      connector: .posix(maxIdleTime: .milliseconds(1))  // Aggressively idle the connection
    ) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let (_, idleCount) = idle.increment()

        switch idleCount {
        case 1:
          // The first idle happens when the load balancer in started, give it an endpoint
          // which it will connect to. Wait for it to be ready and then idle again.
          let endpoint = Endpoint(addresses: context.servers.map { $0.address })
          context.pickFirst!.updateEndpoint(endpoint)
        case 2:
          // Load-balancer has the endpoints but all are idle. Picking will trigger a connect.
          XCTAssertNil(context.loadBalancer.pickSubchannel())
        case 3:
          // Connection idled again. Shut it down.
          context.loadBalancer.close()

        default:
          XCTFail("Became idle too many times")
        }

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testPickFirstConnectionDropReturnsToIdle() async throws {
    // Checks that when the load balancers connection is unexpectedly dropped when there are no
    // open streams that it returns to the idle state.
    let idleCount = AtomicCounter()

    try await LoadBalancerTest.pickFirst(servers: 1, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let (_, newIdleCount) = idleCount.increment()
        switch newIdleCount {
        case 1:
          let endpoint = Endpoint(addresses: context.servers.map { $0.address })
          context.pickFirst!.updateEndpoint(endpoint)
        case 2:
          context.loadBalancer.close()
        default:
          ()
        }

      case .connectivityStateChanged(.ready):
        // Drop the connection.
        context.servers[0].server.clients[0].close(mode: .all, promise: nil)

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }

  func testPickFirstReceivesGoAway() async throws {
    let idleCount = AtomicCounter()
    try await LoadBalancerTest.pickFirst(servers: 2, connector: .posix()) { context, event in
      switch event {
      case .connectivityStateChanged(.idle):
        let (_, newIdleCount) = idleCount.increment()
        switch newIdleCount {
        case 1:
          // Provide the address of the first server.
          context.pickFirst!.updateEndpoint(Endpoint(context.servers[0].address))
        case 2:
          // Provide the address of the second server.
          context.pickFirst!.updateEndpoint(Endpoint(context.servers[1].address))
        default:
          ()
        }

      case .connectivityStateChanged(.ready):
        switch idleCount.value {
        case 1:
          XCTAssertNotNil(context.loadBalancer.pickSubchannel())
          // Must be connected to server 1, send a GOAWAY frame.
          let channel = context.servers[0].server.clients.first!
          let goAway = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: 0, errorCode: .noError, opaqueData: nil)
          )
          channel.writeAndFlush(goAway, promise: nil)

        case 2:
          // Must only be connected to server 2 now.
          XCTAssertEqual(context.servers[0].server.clients.count, 0)
          XCTAssertEqual(context.servers[1].server.clients.count, 1)
          XCTAssertNotNil(context.loadBalancer.pickSubchannel())
          context.loadBalancer.close()

        default:
          ()
        }

      default:
        ()
      }
    } verifyEvents: { events in
      let expected: [LoadBalancerEvent] = [
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .requiresNameResolution,
        .connectivityStateChanged(.idle),
        .connectivityStateChanged(.connecting),
        .connectivityStateChanged(.ready),
        .connectivityStateChanged(.shutdown),
      ]
      XCTAssertEqual(events, expected)
    }
  }
}
