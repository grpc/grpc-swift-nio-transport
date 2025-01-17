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
import GRPCNIOTransportHTTP2
import Testing

@Suite("ChannelDebugCallbacks")
struct ChannelDebugCallbackTests {
  @Test(arguments: TransportKind.allCases, TransportKind.allCases)
  func debugCallbacksAreCalled(serverKind: TransportKind, clientKind: TransportKind) async throws {
    // Validates the callbacks are called appropriately by setting up callbacks which increment
    // counters and then returning those stats from a gRPC service. The client's interactions with
    // the service drive the callbacks.

    let stats = DebugCallbackStats()
    let serverDebug = HTTP2ServerTransport.Config.ChannelDebuggingCallbacks(
      onBindTCPListener: { _ in
        stats.tcpListenersBound.add(1, ordering: .sequentiallyConsistent)
      },
      onAcceptTCPConnection: { _ in
        stats.tcpConnectionsAccepted.add(1, ordering: .sequentiallyConsistent)
      },
      onAcceptHTTP2Stream: { _ in
        stats.http2StreamsAccepted.add(1, ordering: .sequentiallyConsistent)
      }
    )

    let clientDebug = HTTP2ClientTransport.Config.ChannelDebuggingCallbacks(
      onCreateTCPConnection: { _ in
        stats.tcpConnectionsCreated.add(1, ordering: .sequentiallyConsistent)
      },
      onCreateHTTP2Stream: { _ in
        stats.http2StreamsCreated.add(1, ordering: .sequentiallyConsistent)
      }
    )

    // For each server have the client create this many connections.
    let connectionsPerServer = 5
    // For each connection have the client create this many streams.
    let streamsPerConnection = 3

    try await withGRPCServer(
      transport: self.makeServerTransport(
        kind: serverKind,
        address: .ipv4(host: "127.0.0.1", port: 0),
        debug: serverDebug
      ),
      services: [StatsService(stats: stats)]
    ) { server in
      let address = try await server.listeningAddress!.ipv4!
      for connectionNumber in 1 ... connectionsPerServer {
        try await withGRPCClient(
          transport: self.makeClientTransport(
            kind: clientKind,
            target: .ipv4(host: address.host, port: address.port),
            debug: clientDebug
          )
        ) { client in
          let statsClient = StatsClient(wrapping: client)

          // Create a few streams per connection.
          for streamNumber in 1 ... streamsPerConnection {
            let streamCount = (connectionNumber - 1) * streamsPerConnection + streamNumber

            let stats = try await statsClient.getStats()
            #expect(stats.server.tcpListenersBound == 1)
            #expect(stats.server.tcpConnectionsAccepted == connectionNumber)
            #expect(stats.server.http2StreamsAccepted == streamCount)

            #expect(stats.client.tcpConnectionsCreated == connectionNumber)
            #expect(stats.client.http2StreamsCreated == streamCount)
          }
        }
      }
    }
  }

  private func makeServerTransport(
    kind: TransportKind,
    address: SocketAddress,
    debug: HTTP2ServerTransport.Config.ChannelDebuggingCallbacks
  ) -> NIOServerTransport {
    switch kind {
    case .posix:
      return NIOServerTransport(
        .http2NIOPosix(
          address: address,
          transportSecurity: .plaintext,
          config: .defaults {
            $0.channelDebuggingCallbacks = debug
          }
        )
      )
    #if canImport(Network)
    case .transportServices:
      return NIOServerTransport(
        .http2NIOTS(
          address: address,
          transportSecurity: .plaintext,
          config: .defaults {
            $0.channelDebuggingCallbacks = debug
          }
        )
      )
    #endif
    }
  }

  private func makeClientTransport(
    kind: TransportKind,
    target: any ResolvableTarget,
    debug: HTTP2ClientTransport.Config.ChannelDebuggingCallbacks
  ) throws -> NIOClientTransport {
    switch kind {
    case .posix:
      return NIOClientTransport(
        try .http2NIOPosix(
          target: target,
          transportSecurity: .plaintext,
          config: .defaults {
            $0.channelDebuggingCallbacks = debug
          }
        )
      )
    #if canImport(Network)
    case .transportServices:
      return NIOClientTransport(
        try .http2NIOTS(
          target: target,
          transportSecurity: .plaintext,
          config: .defaults {
            $0.channelDebuggingCallbacks = debug
          }
        )
      )
    #endif
    }
  }
}
