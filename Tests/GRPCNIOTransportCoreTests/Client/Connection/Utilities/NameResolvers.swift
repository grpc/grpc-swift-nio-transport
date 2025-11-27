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

import GRPCCore
import GRPCNIOTransportCore
import Synchronization

@available(gRPCSwiftNIOTransport 2.0, *)
extension NameResolver {
  static var empty: Self {
    return NameResolver(
      names: RPCAsyncSequence(wrapping: ConstantAsyncSequence(result: nil)),
      updateMode: .pull
    )
  }

  static func `static`(
    endpoints: [Endpoint],
    serviceConfig: ServiceConfig? = nil
  ) -> Self {
    let result = NameResolutionResult(
      endpoints: endpoints,
      serviceConfig: serviceConfig.map { .success($0) }
    )

    return NameResolver(
      names: RPCAsyncSequence(wrapping: ConstantAsyncSequence(element: result)),
      updateMode: .pull
    )
  }

  static func `static`(throwing error: any Error) -> Self {
    return NameResolver(
      names: RPCAsyncSequence(wrapping: ConstantAsyncSequence(error: error)),
      updateMode: .pull
    )
  }

  static func `dynamic`(
    updateMode: UpdateMode
  ) -> (Self, AsyncThrowingStream<NameResolutionResult, any Error>.Continuation) {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: NameResolutionResult.self)
    let resolver = NameResolver(names: RPCAsyncSequence(wrapping: stream), updateMode: updateMode)
    return (resolver, continuation)
  }

  static func composedOf(
    resolvers: [RPCAsyncSequence<NameResolutionResult, any Error>],
    updateMode: UpdateMode = .pull
  ) -> Self {
    final class CompositeResolver: AsyncSequence, Sendable {
      typealias Element = NameResolutionResult

      private let resolvers: Mutex<[RPCAsyncSequence<NameResolutionResult, any Error>].Iterator>

      init(resolvers: [RPCAsyncSequence<NameResolutionResult, any Error>]) {
        self.resolvers = Mutex(resolvers.makeIterator())
      }

      func makeAsyncIterator() -> AsyncIterator {
        if let resolver = self.resolvers.withLock({ $0.next() }) {
          return AsyncIterator(iterator: resolver.makeAsyncIterator())
        } else {
          struct TooManyResolversUsed: Error {}
          let constant = ConstantAsyncSequence<NameResolutionResult>(error: TooManyResolversUsed())
          let fallback = RPCAsyncSequence(wrapping: constant)
          return AsyncIterator(iterator: fallback.makeAsyncIterator())
        }
      }

      struct AsyncIterator: AsyncIteratorProtocol {
        typealias Element = NameResolutionResult

        private var iterator: RPCAsyncSequence<NameResolutionResult, any Error>.AsyncIterator

        init(iterator: RPCAsyncSequence<NameResolutionResult, any Error>.AsyncIterator) {
          self.iterator = iterator
        }

        mutating func next() async throws -> NameResolutionResult? {
          try Task.checkCancellation()
          return try await self.iterator.next()
        }
      }
    }

    return NameResolver(
      names: RPCAsyncSequence(wrapping: CompositeResolver(resolvers: resolvers)),
      updateMode: updateMode
    )
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
struct ConstantAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {
  private let result: Result<Element, any Error>?

  init(element: Element) {
    self.init(result: .success(element))
  }

  init(error: any Error) {
    self.init(result: .failure(error))
  }

  init(result: Result<Element, any Error>?) {
    self.result = result
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(result: self.result)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    private let result: Result<Element, any Error>?

    fileprivate init(result: Result<Element, any Error>?) {
      self.result = result
    }

    func next() async throws -> Element? {
      try self.result?.get()
    }
  }

}
