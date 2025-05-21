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
private struct ConstantAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {
  private let element: Element

  init(element: Element) {
    self.element = element
  }

  func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(element: self.element)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    private let element: Element

    fileprivate init(element: Element) {
      self.element = element
    }

    func next() async throws -> Element? {
      return self.element
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension RPCAsyncSequence where Element: Sendable, Failure == any Error {
  static func constant(_ element: Element) -> RPCAsyncSequence<Element, any Error> {
    return RPCAsyncSequence(wrapping: ConstantAsyncSequence(element: element))
  }
}
