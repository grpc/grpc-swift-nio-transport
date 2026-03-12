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
import NIOEmbedded
import Testing

@testable import GRPCNIOTransportCore

/// Counts the number of flushes that pass through.
private final class FlushCountingHandler: ChannelOutboundHandler {
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  var flushCount = 0

  func flush(context: ChannelHandlerContext) {
    self.flushCount += 1
    context.flush()
  }
}

struct FlushCoalescingHandlerTests {
  private func makePipeline(
    maxFlushDelay: TimeAmount,
    maxBytes: Int
  ) -> (channel: EmbeddedChannel, pre: FlushCountingHandler, post: FlushCountingHandler) {
    let pre = FlushCountingHandler()
    let coalescing = FlushCoalescingHandler(maxFlushDelay: maxFlushDelay, maxBytes: maxBytes)
    let post = FlushCountingHandler()
    let channel = EmbeddedChannel(handlers: [post, coalescing, pre])
    return (channel, pre, post)
  }

  @Test("Write and flush below threshold schedules delayed flush")
  func writeAndFlushBelowThreshold() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 1024)
    defer { _ = try? channel.finish() }

    #expect(pre.flushCount == 0)
    #expect(post.flushCount == 0)
    let buffer = channel.allocator.buffer(string: "hello")
    channel.writeAndFlush(buffer, promise: nil)

    // Below threshold, no flushes in post.
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 0)

    // Data should still be written through (just not flushed).
    #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)

    // Advance time  to trigger the flush.
    channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)
    let out = try channel.readOutbound(as: ByteBuffer.self)
    #expect(out == buffer)
  }

  @Test("Flush triggered immediately when byte threshold reached")
  func flushOnByteThreshold() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 32)
    defer { _ = try? channel.finish() }

    // Write enough bytes to exceed the threshold.
    let buffer = channel.allocator.buffer(repeating: 0, count: 32)
    channel.writeAndFlush(buffer, promise: nil)

    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)
  }

  @Test("Multiple flushes coalesced into one")
  func multipleFlushesCoalesced() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 1024)
    defer { _ = try? channel.finish() }

    // Write small amounts and flush multiple times.
    for _ in 0 ..< 5 {
      let buffer = channel.allocator.buffer(string: "hi")
      channel.writeAndFlush(buffer, promise: nil)
    }

    // None should have propagated yet.
    #expect(pre.flushCount == 5)
    #expect(post.flushCount == 0)

    // Advance time to trigger the delayed flush.
    channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))

    // All flushes should have been coalesced into one.
    #expect(pre.flushCount == 5)  // Still five
    #expect(post.flushCount == 1)
  }

  @Test("Byte threshold reached across multiple writes triggers flush")
  func byteThresholdAcrossMultipleWrites() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 32)
    defer { _ = try? channel.finish() }

    // First write + flush: below threshold.
    let buffer = channel.allocator.buffer(repeating: 0, count: 16)
    channel.writeAndFlush(buffer, promise: nil)
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 0)

    // Second write hits byte limit.
    channel.writeAndFlush(buffer, promise: nil)
    #expect(pre.flushCount == 2)
    #expect(post.flushCount == 1)
  }

  @Test("Channel close forces pending flush")
  func channelCloseCancelsPendingFlush() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 1024)
    defer { _ = try? channel.finish() }

    let buffer = channel.allocator.buffer(string: "hi")
    channel.writeAndFlush(buffer, promise: nil)
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 0)

    // Close the channel, which forces a flush.
    let close = channel.close()
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)

    // Let the close happen.
    channel.embeddedEventLoop.run()
    try close.wait()

    // Advance time: the callback should have been cancelled so no additional flush.
    channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)
  }

  @Test("Writability change causes flush")
  func channelUnwritableTriggersFlush() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 1024)
    defer { _ = try? channel.finish() }

    let buffer = channel.allocator.buffer(string: "hi")
    channel.writeAndFlush(buffer, promise: nil)
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 0)

    // Trigger a writability change notification which should trigger the flush.
    channel.isWritable = false
    channel.pipeline.fireChannelWritabilityChanged()

    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)
  }

  @Test("Write without flush does not trigger flush")
  func writeWithoutFlush() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 32)
    defer { _ = try? channel.finish() }

    // Write more than max bytes but don't flush.
    let buffer = channel.allocator.buffer(repeating: 0, count: 64)
    channel.write(buffer, promise: nil)

    #expect(pre.flushCount == 0)
    #expect(post.flushCount == 0)

    // Still not flush after the deadline.
    channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
    #expect(pre.flushCount == 0)
    #expect(post.flushCount == 0)

    // Now flush.
    channel.flush()
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)
  }

  @Test("Pending state reset after flush")
  func pendingResetAfterFlush() throws {
    let (channel, pre, post) = self.makePipeline(maxFlushDelay: .milliseconds(10), maxBytes: 32)
    defer { _ = try? channel.finish() }

    // First batch: write enough to trigger immediate flush.
    let buffer = channel.allocator.buffer(repeating: 0, count: 32)
    channel.writeAndFlush(buffer, promise: nil)
    #expect(pre.flushCount == 1)
    #expect(post.flushCount == 1)

    // Second batch: write a small amount. Should not flush immediately.
    let smol = channel.allocator.buffer(string: "smol")
    channel.writeAndFlush(smol, promise: nil)
    #expect(pre.flushCount == 2)
    #expect(post.flushCount == 1)

    // Advance time to get the delayed flush.
    channel.embeddedEventLoop.advanceTime(by: .milliseconds(10))
    #expect(pre.flushCount == 2)
    #expect(post.flushCount == 2)
  }
}
