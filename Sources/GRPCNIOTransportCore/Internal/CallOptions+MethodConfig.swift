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

package import GRPCCore

@available(gRPCSwiftNIOTransport 2.0, *)
extension CallOptions {
  package mutating func formUnion(with methodConfig: MethodConfig?) {
    guard let methodConfig = methodConfig else { return }

    self.timeout.setIfNone(to: methodConfig.timeout)
    self.waitForReady.setIfNone(to: methodConfig.waitForReady)
    self.maxRequestMessageBytes.setIfNone(to: methodConfig.maxRequestMessageBytes)
    self.maxResponseMessageBytes.setIfNone(to: methodConfig.maxResponseMessageBytes)
    self.executionPolicy.setIfNone(to: methodConfig.executionPolicy)
  }
}

extension Optional {
  fileprivate mutating func setIfNone(to value: Self) {
    switch self {
    case .some:
      ()
    case .none:
      self = value
    }
  }
}
