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
import GRPCInProcessTransport
import GRPCNIOTransportHTTP2
import Synchronization
import Testing
import WorkerService

@Suite
struct WorkerServiceTests {
  typealias WorkerClient = Grpc_Testing_WorkerService.Client<InProcessTransport.Client>

  func withWorkerClient(
    _ body: (_ client: WorkerClient) async throws -> Void,
    onQuit: @escaping @Sendable () -> Void = {}
  ) async throws {
    let inProcess = InProcessTransport()
    let service = WorkerService(serverHost: "127.0.0.1", serverPort: nil)
    service.onQuit {
      onQuit()
    }

    try await withGRPCServer(transport: inProcess.server, services: [service]) { _ in
      try await withGRPCClient(transport: inProcess.client) { client in
        try await body(WorkerClient(wrapping: client))
      }
    }
  }

  func withBenchmarkService(
    _ body: (_ server: GRPCServer<HTTP2ServerTransport.Posix>) async throws -> Void
  ) async throws {
    try await withGRPCServer(
      transport: .http2NIOPosix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .plaintext
      ),
      services: [BenchmarkService()]
    ) {
      try await body($0)
    }
  }

  @Test
  func runServer() async throws {
    try await self.withWorkerClient { worker in
      let replies = try await worker.runServer { writer in
        // Start the server.
        let setup = Grpc_Testing_ServerArgs.with {
          $0.setup = .with {
            $0.port = 0
          }
        }
        try await writer.write(setup)

        // Send a mark (should result in stats).
        let mark = Grpc_Testing_ServerArgs.with {
          $0.mark = Grpc_Testing_Mark()
        }
        try await writer.write(mark)

      } onResponse: { response in
        try await response.messages.reduce(into: []) { $0.append($1) }
      }

      // There should be two replies, the port and some stats.
      try #require(replies.count == 2)

      // There should be a port in the first reply.
      #expect(replies[0].port != 0)
      // There should be stats in the second.
      #expect(replies[1].hasStats)
    }
  }

  @Test
  func runClient() async throws {
    // Manually run a benchmark service.
    try await self.withBenchmarkService { benchmark in
      let address = try await benchmark.listeningAddress
      let ipv4 = try #require(address?.ipv4)

      try await self.withWorkerClient { worker in
        let replies = try await worker.runClient { writer in
          let setup = Grpc_Testing_ClientArgs.with {
            $0.setup = .with {
              $0.serverTargets = ["\(ipv4.host):\(ipv4.port)"]
              $0.rpcType = .unary
              $0.outstandingRpcsPerChannel = 1
              $0.clientChannels = 1
              $0.histogramParams = .with {
                $0.resolution = 0.01
                $0.maxPossible = 60e9
              }
            }
          }

          try await writer.write(setup)

          // Pause for a moment while some RPCs complete.
          try await Task.sleep(for: .milliseconds(250))
          let mark = Grpc_Testing_ClientArgs.with {
            $0.mark = Grpc_Testing_Mark()
          }
          try await writer.write(mark)
        } onResponse: { response in
          try await response.messages.reduce(into: []) { $0.append($1) }
        }

        try #require(replies.count == 2)
        #expect(replies[0].hasStats)
        #expect(replies[1].hasStats)

        // At least one latency should've been recorded in 250ms.
        #expect(replies[1].stats.latencies.count > 0)
      }
    }
  }

  @Test
  func clientAndServer() async throws {
    try await withWorkerClient { serverWorker in
      try await withWorkerClient { clientWorker in
        await withThrowingTaskGroup(of: Void.self) { group in
          let port = AsyncStream.makeStream(of: Int.self)
          let delayBeforeStats: Duration = .milliseconds(250)

          // Run the server.
          group.addTask {
            try await serverWorker.runServer { writer in
              // Start the server.
              let setup = Grpc_Testing_ServerArgs.with {
                $0.setup = .with {
                  $0.port = 0
                }
              }
              try await writer.write(setup)

              try await Task.sleep(for: delayBeforeStats)
              let mark = Grpc_Testing_ServerArgs.with {
                $0.mark = Grpc_Testing_Mark()
              }
              try await writer.write(mark)
            } onResponse: { response in
              var stats = [Grpc_Testing_ServerStats]()

              for try await message in response.messages {
                if message.port > 0 {
                  port.continuation.yield(Int(message.port))
                  port.continuation.finish()
                }

                if message.hasStats {
                  stats.append(message.stats)
                }
              }

              // Should be one set of stats.
              try #require(stats.count == 1)
            }

          }

          // Run the client.
          group.addTask {
            try await clientWorker.runClient { writer in
              // Wait for the server worker to report back the server port.
              let maybePort = await port.stream.first(where: { _ in true })
              let port = try #require(maybePort)

              let setup = Grpc_Testing_ClientArgs.with {
                $0.setup = .with {
                  $0.serverTargets = ["127.0.0.1:\(port)"]
                  $0.rpcType = .unary
                  $0.outstandingRpcsPerChannel = 1
                  $0.clientChannels = 1
                  $0.histogramParams = .with {
                    $0.resolution = 0.01
                    $0.maxPossible = 60e9
                  }
                }
              }
              try await writer.write(setup)

              try await Task.sleep(for: delayBeforeStats)
              let mark = Grpc_Testing_ClientArgs.with {
                $0.mark = Grpc_Testing_Mark()
              }
              try await writer.write(mark)
            } onResponse: { response in
              var stats = [Grpc_Testing_ClientStats]()

              for try await message in response.messages {
                if message.hasStats {
                  stats.append(message.stats)
                }
              }

              // Should be two sets of stats.
              try #require(stats.count == 2)
            }
          }
        }
      }
    }
  }

  @Test
  func coreCount() async throws {
    try await self.withWorkerClient { worker in
      let reply = try await worker.coreCount(Grpc_Testing_CoreRequest())
      #expect(reply.cores > 0)
    }
  }

  @Test
  func quit() async throws {
    let didQuit = Mutex(false)

    try await self.withWorkerClient { worker in
      _ = try await worker.quitWorker(Grpc_Testing_Void())
      // Reply is also Grpc_Testing_Void
    } onQuit: {
      didQuit.withLock { $0 = true }
    }

    #expect(didQuit.withLock { $0 })
  }

  @Test
  func quitWhileRunningServer() async throws {
    let didQuit = Mutex(false)

    try await self.withWorkerClient { worker in
      await withThrowingTaskGroup(of: Void.self) { group in
        let serverStarted = AsyncStream.makeStream(of: Void.self)

        // Start a server in the background.
        group.addTask {
          try await worker.runServer { writer in
            let setup = Grpc_Testing_ServerArgs.with {
              $0.setup = .with {
                $0.port = 0
              }
            }
            try await writer.write(setup)

            // Signal that the server has started, then keep the stream open
            // until the server is quit.
            serverStarted.continuation.yield()
            serverStarted.continuation.finish()

            // Wait for the quit to shut down the server. The writer will be
            // cancelled when the server shuts down.
            try await Task.sleep(for: .seconds(30))
          } onResponse: { response in
            for try await _ in response.messages {}
          }
        }

        // Wait for the server to start, then quit.
        for await _ in serverStarted.stream {}
        _ = try? await worker.quitWorker(Grpc_Testing_Void())

        group.cancelAll()
      }
    } onQuit: {
      didQuit.withLock { $0 = true }
    }

    #expect(didQuit.withLock { $0 })
  }

  @Test
  func quitWhileRunningClient() async throws {
    let didQuit = Mutex(false)

    try await self.withBenchmarkService { benchmark in
      let address = try await benchmark.listeningAddress
      let ipv4 = try #require(address?.ipv4)

      try await self.withWorkerClient { worker in
        await withThrowingTaskGroup(of: Void.self) { group in
          let clientStarted = AsyncStream.makeStream(of: Void.self)

          // Start a client in the background.
          group.addTask {
            try await worker.runClient { writer in
              let setup = Grpc_Testing_ClientArgs.with {
                $0.setup = .with {
                  $0.serverTargets = ["\(ipv4.host):\(ipv4.port)"]
                  $0.rpcType = .unary
                  $0.outstandingRpcsPerChannel = 1
                  $0.clientChannels = 1
                  $0.histogramParams = .with {
                    $0.resolution = 0.01
                    $0.maxPossible = 60e9
                  }
                }
              }
              try await writer.write(setup)

              // Signal that the client has started, then keep the stream open
              // until the client is quit.
              clientStarted.continuation.yield()
              clientStarted.continuation.finish()

              // Wait for the quit to shut down the clients.
              try await Task.sleep(for: .seconds(30))
            } onResponse: { response in
              for try await _ in response.messages {}
            }
          }

          // Wait for the client to start, then quit.
          for await _ in clientStarted.stream {}
          _ = try? await worker.quitWorker(Grpc_Testing_Void())

          group.cancelAll()
        }
      } onQuit: {
        didQuit.withLock { $0 = true }
      }
    }

    #expect(didQuit.withLock { $0 })
  }
}
