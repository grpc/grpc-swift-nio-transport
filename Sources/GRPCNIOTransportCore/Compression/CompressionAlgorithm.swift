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

internal import GRPCCore

@available(gRPCSwiftNIOTransport 1.0, *)
extension CompressionAlgorithm {
  init?(name: String) {
    self.init(name: name[...])
  }

  init?(name: Substring) {
    switch name {
    case "gzip":
      self = .gzip
    case "deflate":
      self = .deflate
    case "identity":
      self = .none
    default:
      return nil
    }
  }

  /// The name of the algorithm, if supported.
  var nameIfSupported: String? {
    if self == .gzip {
      return "gzip"
    } else if self == .deflate {
      return "deflate"
    } else if self == .none {
      return "identity"
    } else {
      return nil
    }
  }
}

@available(gRPCSwiftNIOTransport 1.0, *)
extension CompressionAlgorithmSet {
  var count: Int {
    self.rawValue.nonzeroBitCount
  }
}
