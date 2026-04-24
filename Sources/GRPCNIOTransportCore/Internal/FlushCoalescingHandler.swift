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

import NIOCore

internal final class FlushCoalescingHandler: ChannelDuplexHandler {
  internal typealias InboundIn = ByteBuffer
  internal typealias InboundOut = ByteBuffer
  internal typealias OutboundIn = ByteBuffer
  internal typealias OutboundOut = ByteBuffer

  /// Max delay between a flush being requested and it being delivered.
  private let maxFlushDelay: TimeAmount
  /// The number of bytes to write before a flush is emitted.
  private let maxBytes: Int

  struct Pending {
    /// Number of bytes written without a flush.
    var bytes: Int
    /// Number of flushes requested but not yet delivered.
    var flushes: Int

    mutating func reset() {
      self.bytes = 0
      self.flushes = 0
    }
  }

  /// The number of pending flushes and bytes.
  private var pending: Pending

  /// Callback to trigger a flush.
  private var flushCallback: NIOScheduledCallback?
  /// Context; nil'd out when the handler is removed from the pipeline.
  private var context: ChannelHandlerContext?

  internal init(maxFlushDelay: TimeAmount, maxBytes: Int) {
    self.pending = Pending(bytes: 0, flushes: 0)
    self.maxFlushDelay = maxFlushDelay
    self.maxBytes = maxBytes
    self.flushCallback = nil
  }

  internal func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
  }

  internal func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
    self.flushCallback?.cancel()
    self.flushCallback = nil
  }

  internal func channelWritabilityChanged(context: ChannelHandlerContext) {
    let isWritable = context.channel.isWritable

    if !isWritable && self.pending.flushes > 0 {
      // Stopped being writable: flush out any bytes.
      self.flushNow(context: context)
    }

    context.fireChannelWritabilityChanged()
  }

  internal func write(
    context: ChannelHandlerContext,
    data: NIOAny,
    promise: EventLoopPromise<Void>?
  ) {
    let buffer = self.unwrapOutboundIn(data)
    self.pending.bytes += buffer.readableBytes

    context.write(data, promise: promise)

    guard self.pending.flushes > 0 else { return }

    if self.pending.bytes >= self.maxBytes {
      self.flushNow(context: context)
    } else {
      self.scheduleCallbackIfNecessary(context: context)
    }
  }

  internal func flush(context: ChannelHandlerContext) {
    self.pending.flushes += 1

    if self.pending.bytes >= self.maxBytes {
      self.flushNow(context: context)
    } else {
      self.scheduleCallbackIfNecessary(context: context)
    }
  }

  internal func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?
  ) {
    if self.pending.flushes > 0 {
      self.flushNow(context: context)
    }

    context.close(mode: mode, promise: promise)
  }

  private func scheduleCallbackIfNecessary(context: ChannelHandlerContext) {
    guard self.flushCallback == nil else { return }

    // Can fail if the event-loop has shut down.
    self.flushCallback = try? context.eventLoop.scheduleCallback(
      in: self.maxFlushDelay,
      handler: FlushCallbackHandler(NIOLoopBound(self, eventLoop: context.eventLoop))
    )
  }

  private func flushNow(context: ChannelHandlerContext) {
    self.flushCallback?.cancel()
    self.flushCallback = nil
    self.pending.reset()
    context.flush()
  }

  private func handleFlushCallback() {
    if let context = self.context {
      self.flushNow(context: context)
    }
  }

  struct FlushCallbackHandler: Sendable, NIOScheduledCallbackHandler {
    let handler: NIOLoopBound<FlushCoalescingHandler>

    init(_ handler: NIOLoopBound<FlushCoalescingHandler>) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      if handler.eventLoop === eventLoop {
        handler.value.handleFlushCallback()
      } else {
        handler.eventLoop.execute {
          handler.value.handleFlushCallback()
        }
      }
    }
  }
}
