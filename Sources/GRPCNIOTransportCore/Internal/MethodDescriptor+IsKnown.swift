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

internal import GRPCCore

@available(gRPCSwiftNIOTransport 2.4, *)
extension Optional where Wrapped == MethodDescriptor.RPCType {
  /// Whehter the type is known to not be a request streaming RPC. If the type isn't known then
  /// `false` is returned.
  internal var isKnownUnaryRequest: Bool {
    switch self {
    case .some(let type):
      return !type.isRequestStreaming
    case .none:
      return false
    }
  }

  /// Whehter the type is known to not be a response streaming RPC. If the type isn't known then
  /// `false` is returned.
  internal var isKnownUnaryResponse: Bool {
    switch self {
    case .some(let type):
      return !type.isResponseStreaming
    case .none:
      return false
    }
  }
}
