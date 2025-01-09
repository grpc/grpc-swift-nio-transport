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

import GRPCCore
import Synchronization

final class DebugCallbackStats: Sendable {
  let tcpListenersBound: Atomic<Int>
  let tcpConnectionsAccepted: Atomic<Int>
  let tcpConnectionsCreated: Atomic<Int>

  let http2StreamsAccepted: Atomic<Int>
  let http2StreamsCreated: Atomic<Int>

  init() {
    self.tcpListenersBound = Atomic(0)
    self.tcpConnectionsAccepted = Atomic(0)
    self.tcpConnectionsCreated = Atomic(0)

    self.http2StreamsAccepted = Atomic(0)
    self.http2StreamsCreated = Atomic(0)
  }

  var serverStats: GetStatsResponse.Server {
    GetStatsResponse.Server(
      tcpListenersBound: self.tcpListenersBound.load(ordering: .sequentiallyConsistent),
      tcpConnectionsAccepted: self.tcpConnectionsAccepted.load(ordering: .sequentiallyConsistent),
      http2StreamsAccepted: self.http2StreamsAccepted.load(ordering: .sequentiallyConsistent)
    )
  }

  var clientStats: GetStatsResponse.Client {
    GetStatsResponse.Client(
      tcpConnectionsCreated: self.tcpConnectionsCreated.load(ordering: .sequentiallyConsistent),
      http2StreamsCreated: self.http2StreamsCreated.load(ordering: .sequentiallyConsistent)
    )
  }
}

struct StatsService {
  private let stats: DebugCallbackStats

  init(stats: DebugCallbackStats) {
    self.stats = stats
  }

  func getStats() async throws -> GetStatsResponse {
    GetStatsResponse(server: self.stats.serverStats, client: self.stats.clientStats)
  }
}

extension StatsService: RegistrableRPCService {
  func registerMethods(with router: inout RPCRouter) {
    router.registerHandler(
      forMethod: .getStats,
      deserializer: JSONCoder<GetStatsRequest>(),
      serializer: JSONCoder<GetStatsResponse>()
    ) { request, context in
      _ = try await ServerRequest(stream: request)
      let response = try await self.getStats()
      return StreamingServerResponse {
        try await $0.write(response)
        return [:]
      }
    }
  }
}

struct StatsClient {
  private let underlying: GRPCClient

  init(wrapping underlying: GRPCClient) {
    self.underlying = underlying
  }

  func getStats() async throws -> GetStatsResponse {
    try await self.underlying.unary(
      request: ClientRequest(message: GetStatsRequest()),
      descriptor: .getStats,
      serializer: JSONCoder<GetStatsRequest>(),
      deserializer: JSONCoder<GetStatsResponse>(),
      options: .defaults
    ) {
      try $0.message
    }
  }
}

extension MethodDescriptor {
  static let getStats = Self(fullyQualifiedService: "StatsService", method: "GetStats")
}

struct GetStatsRequest: Codable, Hashable {}
struct GetStatsResponse: Codable, Hashable {
  struct Server: Codable, Hashable {
    var tcpListenersBound: Int
    var tcpConnectionsAccepted: Int
    var http2StreamsAccepted: Int
  }

  struct Client: Codable, Hashable {
    var tcpConnectionsCreated: Int
    var http2StreamsCreated: Int
  }

  var server: Server
  var client: Client
}
