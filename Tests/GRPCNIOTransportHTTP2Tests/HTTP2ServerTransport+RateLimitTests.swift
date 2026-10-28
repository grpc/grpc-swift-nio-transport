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
import GRPCNIOTransportHTTP2
import NIOCore
import NIOHTTP2
import NIOPosix
import Testing

@Suite("Server rate limits")
struct HTTP2ServerTransportRateLimitTests {
  @Test("Server closes the connection when the client exceeds the control frame limit")
  @available(gRPCSwiftNIOTransport 2.12, *)
  func controlFrameRateLimitExceeded() async throws {
    let limit = 10

    let transport = HTTP2ServerTransport.Posix(
      address: .ipv4(host: "127.0.0.1", port: 0),
      transportSecurity: .plaintext,
      config: .defaults { config in
        config.http2.rateLimits.controlFrames = RateLimit(maxCount: limit, window: .seconds(60))
        // Permit any number of keepalive pings so that only the control frame limit applies.
        config.connection.keepalive.clientBehavior = .init(
          minPingIntervalWithoutCalls: .zero,
          allowWithoutCalls: true
        )
      }
    )

    try await withGRPCServer(transport: transport, services: []) { _ in
      let address = try await transport.listeningAddress.ipv4!
      let connection = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
        .connect(host: address.host, port: address.port) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(NIOHTTP2Handler(mode: .client))
            return try NIOAsyncChannel<HTTP2Frame, HTTP2Frame>(
              wrappingChannelSynchronously: channel
            )
          }
        }

      let pingCount = limit + 10
      let errorCode: HTTP2ErrorCode? = try await connection.executeThenClose { inbound, outbound in
        // Send more PING frames than the rate limit allows.
        for i in 0 ..< pingCount {
          let ping = HTTP2Frame(
            streamID: .rootStream,
            payload: .ping(HTTP2PingData(withInteger: UInt64(i)), ack: false)
          )
          try await outbound.write(ping)
        }

        // Wait until the server sends a GOAWAY frame or acknowledges every ping.
        var pingAcks = 0
        for try await frame in inbound {
          switch frame.payload {
          case .goAway(_, let code, _):
            return code

          case .ping(_, ack: true):
            pingAcks += 1
            if pingAcks == pingCount {
              return nil
            }

          default:
            ()
          }
        }

        return nil
      }

      #expect(errorCode == .enhanceYourCalm)
    }
  }
}
