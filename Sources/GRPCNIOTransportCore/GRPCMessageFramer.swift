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
internal import NIOCore

/// A ``GRPCMessageFramer`` helps with the framing of gRPC data frames:
/// - It prepends data with the required metadata (compression flag and message length).
/// - It compresses messages using the specified compression algorithm (if configured).
/// - It coalesces multiple messages (appended into the `Framer` by calling ``append(_:compress:)``)
/// into a single `ByteBuffer`.
@available(gRPCSwiftNIOTransport 2.0, *)
struct GRPCMessageFramer {
  /// Length of the gRPC message header (1 compression byte, 4 bytes for the length).
  static let metadataLength = 5

  /// Maximum size the `writeBuffer` can be when concatenating multiple frames.
  /// This limit will not be considered if only a single message/frame is written into the buffer, meaning
  /// frames with messages over 64KB can still be written.
  /// - Note: This is expressed as the power of 2 closer to 64KB (i.e., 64KiB) because `ByteBuffer`
  /// reserves capacity in powers of 2. This way, we can take advantage of the whole buffer.
  static let maxWriteBufferLength = 65_536

  private var pendingMessages: OneOrManyQueue<(bytes: ByteBuffer, promise: EventLoopPromise<Void>?)>

  private var writeBuffer: ByteBuffer

  /// Create a new ``GRPCMessageFramer``.
  init() {
    self.pendingMessages = OneOrManyQueue()
    self.writeBuffer = ByteBuffer()
  }

  /// Queue the given bytes to be framed and potentially coalesced alongside other messages in a `ByteBuffer`.
  /// The resulting data will be returned when calling ``GRPCMessageFramer/next()``.
  mutating func append(_ bytes: ByteBuffer, promise: EventLoopPromise<Void>?) {
    self.pendingMessages.append((bytes, promise))
  }

  /// If there are pending messages to be framed, a `ByteBuffer` will be returned with the framed data.
  /// Data may also be compressed (if configured) and multiple frames may be coalesced into the same `ByteBuffer`.
  /// - Parameter compressor: An optional compressor: if present, payloads will be compressed; otherwise
  /// they'll be framed as-is.
  /// - Throws: If an error is encountered, such as a compression failure, an error will be thrown.
  mutating func nextResult(
    compressor: Zlib.Compressor? = nil
  ) -> (result: Result<ByteBuffer, RPCError>, promise: EventLoopPromise<Void>?)? {
    if self.pendingMessages.isEmpty {
      // Nothing pending: exit early.
      return nil
    }

    defer {
      // To avoid holding an excessively large buffer, if its size is larger than
      // our threshold (`maxWriteBufferLength`), then reset it to a new `ByteBuffer`.
      if self.writeBuffer.capacity > Self.maxWriteBufferLength {
        self.writeBuffer = ByteBuffer()
      }
    }

    var requiredCapacity = 0
    for message in self.pendingMessages {
      requiredCapacity += message.bytes.readableBytes + Self.metadataLength
    }
    self.writeBuffer.clear(minimumCapacity: requiredCapacity)

    var pendingWritePromise: EventLoopPromise<Void>?
    while let message = self.pendingMessages.pop() {
      pendingWritePromise.setOrCascade(to: message.promise)

      do {
        try self.encode(message.bytes, compressor: compressor)
      } catch let rpcError {
        return (result: .failure(rpcError), promise: pendingWritePromise)
      }
    }

    return (result: .success(self.writeBuffer), promise: pendingWritePromise)
  }

  private mutating func encode(
    _ message: ByteBuffer,
    compressor: Zlib.Compressor?
  ) throws(RPCError) {
    if let compressor {
      self.writeBuffer.writeInteger(UInt8(1))  // Set compression flag

      // Write zeroes as length - we'll write the actual compressed size after compression.
      let lengthIndex = self.writeBuffer.writerIndex
      self.writeBuffer.writeInteger(UInt32(0))

      // Compress and overwrite the payload length field with the right length.
      do {
        let writtenBytes = try compressor.compress(message, into: &self.writeBuffer)
        self.writeBuffer.setInteger(UInt32(writtenBytes), at: lengthIndex)
      } catch let zlibError {
        throw RPCError(code: .internalError, message: "Compression failed", cause: zlibError)
      }
    } else {
      self.writeBuffer.writeMultipleIntegers(
        UInt8(0),  // Clear compression flag
        UInt32(message.readableBytes)  // Set message length
      )
      self.writeBuffer.writeImmutableBuffer(message)
    }
  }
}
