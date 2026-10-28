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

/// A limit on the number of events permitted within a time duration.
///
/// The limit is exceeded when more than ``maxCount`` events occur within the ``window`` duration.
@available(gRPCSwiftNIOTransport 2.12, *)
public struct RateLimit: Sendable, Hashable {
  /// The maximum number of events permitted within the ``window`` duration.
  ///
  /// The value is clamped to the range `0 ... 65535`.
  public var maxCount: Int

  /// The length of the sliding window over which events are counted.
  ///
  /// Negative durations are treated as zero.
  public var window: Duration

  /// Creates a rate limit.
  public init(maxCount: Int, window: Duration) {
    self.maxCount = maxCount
    self.window = window
  }
}
