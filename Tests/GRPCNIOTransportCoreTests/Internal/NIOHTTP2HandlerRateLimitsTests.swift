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

import NIOCore
import NIOHTTP2
import Testing

@testable import GRPCNIOTransportCore

struct NIOHTTP2HandlerRateLimitsTests {
  private static func expectedConfiguration(
    maxCount: Int,
    window: TimeAmount
  ) -> NIOHTTP2Handler.Configuration {
    var config = NIOHTTP2Handler.Configuration()
    config.connection.controlFrameRateLimit.maximumCount = maxCount
    config.connection.controlFrameRateLimit.windowLength = window
    return config
  }

  @Test("Server defaults are applied to the HTTP/2 handler configuration")
  @available(gRPCSwiftNIOTransport 2.12, *)
  func serverDefaults() {
    var config = NIOHTTP2Handler.Configuration()
    let defaultLimits = HTTP2ServerTransport.Config.HTTP2.RateLimits.defaults

    config.connection.apply(defaultLimits)

    #expect(config == Self.expectedConfiguration(maxCount: 200, window: .seconds(10)))
  }

  @Test("Client defaults are applied to the HTTP/2 handler configuration")
  @available(gRPCSwiftNIOTransport 2.12, *)
  func clientDefaults() {
    var config = NIOHTTP2Handler.Configuration()
    let defaultLimits = HTTP2ClientTransport.Config.HTTP2.RateLimits.defaults

    config.connection.apply(defaultLimits)

    #expect(config == Self.expectedConfiguration(maxCount: 200, window: .seconds(10)))
  }

  @Test(
    "Max counts are clamped",
    arguments: [
      (Int.min, 0),
      (-1, 0),
      (0, 0),
      (65_535, 65_535),
      (65_536, 65_535),
      (Int.max, 65_535),
    ]
  )
  @available(gRPCSwiftNIOTransport 2.12, *)
  func maxCountIsClamped(maxCount: Int, expected: Int) {
    let expectedConfig = Self.expectedConfiguration(maxCount: expected, window: .seconds(1))

    var serverLimits = HTTP2ServerTransport.Config.HTTP2.RateLimits.defaults
    serverLimits.controlFrames = .init(maxCount: maxCount, window: .seconds(1))

    var serverConfig = NIOHTTP2Handler.Configuration()
    serverConfig.connection.apply(serverLimits)
    #expect(serverConfig == expectedConfig)

    var clientLimits = HTTP2ClientTransport.Config.HTTP2.RateLimits.defaults
    clientLimits.controlFrames = .init(maxCount: maxCount, window: .seconds(1))

    var clientConfig = NIOHTTP2Handler.Configuration()
    clientConfig.connection.apply(clientLimits)
    #expect(clientConfig == expectedConfig)
  }

  @Test(
    "Negative windows are clamped to zero",
    arguments: [
      (Duration.seconds(-1), TimeAmount.zero),
      (Duration.zero, TimeAmount.zero),
      (Duration.milliseconds(1500), TimeAmount.milliseconds(1500)),
    ]
  )
  @available(gRPCSwiftNIOTransport 2.12, *)
  func negativeWindowIsClamped(window: Duration, expected: TimeAmount) {
    let expectedConfig = Self.expectedConfiguration(maxCount: 1, window: expected)

    var serverLimits = HTTP2ServerTransport.Config.HTTP2.RateLimits.defaults
    serverLimits.controlFrames = .init(maxCount: 1, window: window)

    var serverConfig = NIOHTTP2Handler.Configuration()
    serverConfig.connection.apply(serverLimits)
    #expect(serverConfig == expectedConfig)

    var clientLimits = HTTP2ClientTransport.Config.HTTP2.RateLimits.defaults
    clientLimits.controlFrames = .init(maxCount: 1, window: window)

    var clientConfig = NIOHTTP2Handler.Configuration()
    clientConfig.connection.apply(clientLimits)
    #expect(clientConfig == expectedConfig)
  }
}
