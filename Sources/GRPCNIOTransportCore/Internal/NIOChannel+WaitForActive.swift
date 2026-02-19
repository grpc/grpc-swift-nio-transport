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

package import NIOCore

package final class WaitForActive: ChannelInboundHandler, RemovableChannelHandler {
  package typealias InboundIn = Any

  private let promise: EventLoopPromise<Void>

  package var isActive: EventLoopFuture<Void> {
    self.promise.futureResult
  }

  package init(promise: EventLoopPromise<Void>) {
    self.promise = promise
  }

  package func handlerAdded(context: ChannelHandlerContext) {
    if context.channel.isActive {
      context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
      self.promise.succeed()
    }
  }

  package func channelActive(context: ChannelHandlerContext) {
    context.fireChannelActive()
    context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    self.promise.succeed()
  }

  package func channelInactive(context: ChannelHandlerContext) {
    context.fireChannelInactive()
    self.promise.fail(ChannelError.alreadyClosed)
  }

  package func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.promise.fail(error)
    context.fireErrorCaught(error)
  }
}

extension Channel {
  func waitUntilActive() -> EventLoopFuture<Void> {
    self.eventLoop.flatSubmit {
      do {
        let waitForActive = try self.pipeline.syncOperations.handler(type: WaitForActive.self)
        return waitForActive.isActive
      } catch {
        // The handler isn't expected to be present in all connections.
        return self.eventLoop.makeSucceededVoidFuture()
      }
    }
  }
}
