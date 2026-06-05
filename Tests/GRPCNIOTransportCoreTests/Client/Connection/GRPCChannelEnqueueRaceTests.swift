/*
 * Copyright 2026, gRPC Authors All rights reserved.
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
import Testing

@testable import GRPCNIOTransportCore

struct GRPCChannelEnqueueRaceTests {
  /// Regression test: a stream request joins the queue while the load‑balancer
  /// is `.connecting` (or `idle`). The load balancer transitions to `.ready`
  /// (draining the empty queue) *before* `enqueue` acquires the lock on the
  /// state‑machine.
  @Test
  @available(gRPCSwiftNIOTransport 2.8, *)
  func enqueueAfterLoadBalancerBecomesReadyDoesNotStrand() async throws {
    var sm = GRPCChannel.StateMachine()
    sm.start()

    // Install a pick-first load-balancer.
    let pickFirst = PickFirstLoadBalancer(
      connector: NeverConnector(),
      authority: nil,
      backoff: .defaults,
      defaultCompression: .none,
      enabledCompression: .none
    )

    let onChange = sm.changeLoadBalancerKind(to: .pickFirst(.init())) {
      .pickFirst(pickFirst)
    }

    guard case .runLoadBalancer(let lb, stop: let toStop) = onChange else {
      Issue.record("Expected .runLoadBalancer, got \(onChange)")
      return
    }

    #expect(toStop == nil)
    #expect(lb.id == pickFirst.id)

    // Walk the load-balancer through .idle -> .connecting -> .ready. The queue is
    // empty so neither transition resumes any continuations.
    var actions = sm.loadBalancerStateChanged(to: .connecting, id: lb.id)
    #expect(actions.resumeContinuations == nil)
    #expect(actions.publishState == .connecting)

    actions = sm.loadBalancerStateChanged(to: .ready, id: lb.id)
    #expect(actions.publishState == .ready)

    if let resumable = actions.resumeContinuations {
      #expect(resumable.continuations.isEmpty)
      #expect(try resumable.result.map { $0.id }.get() == lb.id)
    } else {
      Issue.record("Expected resumeContinuations to have the LB")
    }

    // Call `enqueue`: this is where the race could happen. Previously the state machine
    // would store the continuation when the connectivity state is .ready.
    let resolved: LoadBalancer = try await withCheckedThrowingContinuation { cont in
      let outcome = sm.enqueue(continuation: cont, waitForReady: false, id: QueueEntryID())
      switch outcome {
      case .use(let lb):
        cont.resume(returning: lb)
      case .poke, .enqueued, .rejected:
        cont.resume(throwing: UnexpectedOutcome(description: "\(outcome)"))
      }
    }
    #expect(resolved.id == pickFirst.id)
  }

  private struct UnexpectedOutcome: Error, CustomStringConvertible {
    let description: String
  }
}
