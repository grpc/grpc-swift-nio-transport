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

struct ThrowingAsyncSequence<Element, Failure: Error>: AsyncSequence {
  typealias Element = Element
  typealias Failure = Failure

  let error: Failure

  init(of: Element.Type = Element.self, error: Failure) {
    self.error = error
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(error: self.error)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let error: Failure

    func next() async throws(Failure) -> Element? {
      throw self.error
    }
  }
}

@available(gRPCSwiftNIOTransport 2.2, *)
extension RPCAsyncSequence {
  static func throwing(_ error: Failure) -> Self {
    RPCAsyncSequence(wrapping: ThrowingAsyncSequence(of: Element.self, error: error))
  }
}
