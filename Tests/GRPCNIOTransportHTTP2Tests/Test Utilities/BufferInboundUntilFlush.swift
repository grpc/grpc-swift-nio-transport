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

/// Buffers inbound bytes until the first flush.
///
/// Some tests using the 'WrappedChannel' client transport create a NIO channel with an
/// empty pipeline and pass it to the transport to configure it. However, the server may send its
/// initial SETTINGS frame before the pipeline is configured which would result in the frame
/// being dropped. This results in unnecessary connection errors.
///
/// This handler works around the issue by buffering inbound bytes until the first flush
/// happens (which would be the HTTP/2 connection preface). It should be added to the channel
/// pipeline before being passed to the 'WrappedChannel'.
final class BufferInboundUntilFlush: ChannelDuplexHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private var accumulated: ByteBuffer?
  private var isBuffering: Bool

  init() {
    self.accumulated = nil
    self.isBuffering = true
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if self.isBuffering {
      let buffer = self.unwrapInboundIn(data)
      self.accumulated.setOrWriteImmutableBuffer(buffer)
    } else {
      context.fireChannelRead(data)
    }
  }

  func flush(context: ChannelHandlerContext) {
    if self.isBuffering {
      self.isBuffering = false
      if let buffered = self.accumulated.take() {
        context.fireChannelRead(self.wrapInboundOut(buffered))
      }
    }

    context.flush()
  }
}
