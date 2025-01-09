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

package import NIOCore

extension EventLoopFuture where Value: Sendable {
  package func runCallbackIfSet(
    on channel: any Channel,
    callback: (@Sendable (any Channel) async throws -> Void)?
  ) -> EventLoopFuture<Value> {
    guard let initializer = callback else { return self }

    // The code below code is equivalent to the following but avoids allocating an extra future.
    //
    //   return self.flatMap { value in
    //     self.eventLoop.makeFutureWithTask {
    //       try await userInitializer(channel)
    //     }.map {
    //       value
    //     }
    //   }
    //
    let promise = self.eventLoop.makePromise(of: Value.self)
    self.whenComplete { result in
      switch result {
      case .success(let value):
        Task {
          do {
            try await initializer(channel)
            promise.succeed(value)
          } catch {
            promise.fail(error)
          }
        }

      case .failure(let error):
        promise.fail(error)
      }
    }

    return promise.futureResult
  }
}
