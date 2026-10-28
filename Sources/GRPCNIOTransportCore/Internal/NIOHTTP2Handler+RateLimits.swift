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

internal import NIOCore
internal import NIOHTTP2

@available(gRPCSwiftNIOTransport 2.12, *)
extension NIOHTTP2Handler.ConnectionConfiguration {
  /// Applies the server transport's rate limits to the HTTP/2 handler configuration.
  mutating func apply(_ rateLimits: HTTP2ServerTransport.Config.HTTP2.RateLimits) {
    self.applyControlFrameRateLimit(rateLimits.controlFrames)
  }

  /// Applies the client transport's rate limits to the HTTP/2 handler configuration.
  mutating func apply(_ rateLimits: HTTP2ClientTransport.Config.HTTP2.RateLimits) {
    self.applyControlFrameRateLimit(rateLimits.controlFrames)
  }

  /// Applies the control frame rate limit to the HTTP/2 handler configuration.
  ///
  /// - Note: The max count is clamped to `0 ... 65535`. A negative window is clamped to zero.
  private mutating func applyControlFrameRateLimit(_ rateLimit: RateLimit) {
    self.controlFrameRateLimit.maximumCount = min(max(rateLimit.maxCount, 0), Int(UInt16.max))
    self.controlFrameRateLimit.windowLength = TimeAmount(max(rateLimit.window, .zero))
  }
}
