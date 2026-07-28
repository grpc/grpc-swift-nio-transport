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

public import GRPCCore
public import NIOCore

/// The contiguous bytes type used by gRPC's NIO transport.
@available(gRPCSwiftNIOTransport 2.0, *)
public struct GRPCNIOTransportBytes: GRPCContiguousBytes, Hashable, Sendable {
  @usableFromInline
  internal var buffer: ByteBuffer

  @inlinable
  internal init(_ buffer: ByteBuffer) {
    self.buffer = buffer
  }

  @inlinable
  internal init() {
    self.buffer = ByteBuffer()
  }

  /// Creates a new instance filled with the given byte, repeated `count` times.
  @inlinable
  public init(repeating: UInt8, count: Int) {
    self.buffer = ByteBuffer(repeating: repeating, count: count)
  }

  /// Creates a new instance from a sequence of bytes.
  @inlinable
  public init(_ sequence: some Sequence<UInt8>) {
    self.buffer = ByteBuffer(bytes: sequence)
  }

  /// The number of bytes stored.
  @inlinable
  public var count: Int {
    self.buffer.readableBytes
  }

  /// Calls the given closure with a pointer to the underlying contiguous storage.
  @inlinable
  public func withUnsafeBytes<R>(
    _ body: (UnsafeRawBufferPointer) throws -> R
  ) rethrows -> R {
    try self.buffer.withUnsafeReadableBytes(body)
  }

  /// Calls the given closure with a mutable pointer to the underlying contiguous storage.
  @inlinable
  public mutating func withUnsafeMutableBytes<R>(
    _ body: (UnsafeMutableRawBufferPointer) throws -> R
  ) rethrows -> R {
    // 'GRPCContiguousBytes' has no concept of readable/writable bytes; all bytes stored are
    // readable and writable. In 'ByteBuffer' terms, these are just the readable bytes.
    try self.buffer.withUnsafeMutableReadableBytes(body)
  }
}
