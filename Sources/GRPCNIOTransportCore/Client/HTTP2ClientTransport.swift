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

public import GRPCCore
public import NIOCore

/// A namespace for the HTTP/2 client transport.
@available(gRPCSwiftNIOTransport 2.0, *)
public enum HTTP2ClientTransport: Sendable {}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport {
  /// A namespace for HTTP/2 client transport configuration.
  public enum Config: Sendable {}
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.Config {
  public struct Compression: Sendable, Hashable {
    /// The default algorithm used for compressing outbound messages.
    ///
    /// This can be overridden on a per-call basis via `CallOptions`.
    public var algorithm: CompressionAlgorithm

    /// Compression algorithms enabled for inbound messages.
    ///
    /// - Note: `CompressionAlgorithm.none` is always supported, even if it isn't set here.
    public var enabledAlgorithms: CompressionAlgorithmSet

    /// Creates a new compression configuration.
    ///
    /// - SeeAlso: ``defaults``.
    public init(algorithm: CompressionAlgorithm, enabledAlgorithms: CompressionAlgorithmSet) {
      self.algorithm = algorithm
      self.enabledAlgorithms = enabledAlgorithms
    }

    /// Default values, compression is disabled.
    public static var defaults: Self {
      Self(algorithm: .none, enabledAlgorithms: .none)
    }
  }

  public struct Keepalive: Sendable, Hashable {
    /// The amount of time to wait after reading data before sending a keepalive ping.
    ///
    /// - Note: The transport may choose to increase this value if it is less than 10 seconds.
    public var time: Duration

    /// The amount of time the server has to respond to a keepalive ping before the connection
    /// is closed.
    public var timeout: Duration

    /// Whether the client sends keepalive pings when there are no calls in progress.
    public var allowWithoutCalls: Bool

    /// Creates a new keepalive configuration.
    public init(time: Duration, timeout: Duration, allowWithoutCalls: Bool) {
      self.time = time
      self.timeout = timeout
      self.allowWithoutCalls = allowWithoutCalls
    }
  }

  public struct Connection: Sendable, Hashable {
    /// The maximum amount of time a connection may be idle before it's closed.
    ///
    /// Connections are considered idle when there are no open streams on them. Idle connections
    /// can be closed after a configured amount of time to free resources. Note that servers may
    /// separately monitor and close idle connections.
    public var maxIdleTime: Duration?

    /// Configuration for keepalive.
    ///
    /// Keepalive is typically applied to connection which have open streams. It can be useful to
    /// detect dropped connections, particularly if the streams running on a connection don't have
    /// much activity.
    ///
    /// See also: gRFC A8: Client-side Keepalive.
    public var keepalive: Keepalive?

    /// Configuration for flush coalescing.
    ///
    /// Flush coalescing delays flushing outbound writes on the HTTP/2 connection to batch them
    /// together, reducing the number of syscalls. For high-traffic workloads this typically
    /// reduces both CPU usage and latency as fewer, larger writes are more efficient. For
    /// low-traffic workloads the delay may add a small amount of latency (bounded by
    /// ``FlushCoalescing/maxFlushDelay``) as there are fewer writes to coalesce.
    ///
    /// If `nil`, flush coalescing is disabled and each flush is passed through immediately.
    @available(gRPCSwiftNIOTransport 2.8, *)
    public var flushCoalescing: FlushCoalescing?

    /// Creates a connection configuration.
    ///
    /// New properties and features added to `Connection` are disabled by default when using
    /// this initializer. Use ``defaults`` to get a configuration with all features enabled
    /// at their default values.
    public init(maxIdleTime: Duration, keepalive: Keepalive?) {
      self.init(maxIdleTime: maxIdleTime, keepalive: keepalive, flushCoalescing: nil)
    }

    @available(gRPCSwiftNIOTransport 2.8, *)
    private init(maxIdleTime: Duration, keepalive: Keepalive?, flushCoalescing: FlushCoalescing?) {
      self.maxIdleTime = maxIdleTime
      self.keepalive = keepalive
      self.flushCoalescing = flushCoalescing
    }

    /// Default values, a 30 minute max idle time, no keepalive, and flush coalescing enabled
    /// with default values.
    public static var defaults: Self {
      Self(maxIdleTime: .seconds(30 * 60), keepalive: nil, flushCoalescing: .defaults)
    }
  }

  public struct Backoff: Sendable, Hashable {
    /// The initial duration to wait before reattempting to establish a connection.
    public var initial: Duration

    /// The maximum duration to wait (before jitter is applied) to wait between connect attempts.
    public var max: Duration

    /// The scaling factor applied to the backoff duration between connect attempts.
    public var multiplier: Double

    /// An amount to randomize the backoff by.
    ///
    /// If backoff is computed to be 10 seconds and jitter is set to `0.2`, then the amount of
    /// jitter will be selected randomly from the range `-0.2 ✕ 10` seconds to `0.2 ✕ 10` seconds.
    /// The resulting backoff will therefore be between 8 seconds and 12 seconds.
    public var jitter: Double

    /// Creates a new backoff configuration.
    public init(initial: Duration, max: Duration, multiplier: Double, jitter: Double) {
      self.initial = initial
      self.max = max
      self.multiplier = multiplier
      self.jitter = jitter
    }

    /// Default values, initial backoff is one second and maximum back off is two minutes. The
    /// multiplier is `1.6` and the jitter is set to `0.2`.
    public static var defaults: Self {
      Self(initial: .seconds(1), max: .seconds(120), multiplier: 1.6, jitter: 0.2)
    }
  }

  public struct HTTP2: Sendable, Hashable {
    /// The max frame size, in bytes.
    ///
    /// The actual value used is clamped to `(1 << 14) ... (1 << 24) - 1` (the min and max values
    /// allowed by RFC 9113 § 6.5.2).
    public var maxFrameSize: Int

    /// The target flow control window size, in bytes.
    ///
    /// The value is clamped to `... (1 << 31) - 1`.
    public var targetWindowSize: Int

    /// The authority of the server.
    ///
    /// Any value set here will unconditionally override any value derived from the target address.
    ///
    /// The server authority is used in the ":authority" pseudoheader and in the TLS SNI
    /// extension, if applicable.
    public var authority: String?

    /// Creates a new HTTP/2 configuration.
    public init(maxFrameSize: Int, targetWindowSize: Int, authority: String?) {
      self.maxFrameSize = maxFrameSize
      self.targetWindowSize = targetWindowSize
      self.authority = authority
    }

    /// Default values, max frame size is 16KiB, and the target window size is 8MiB.
    public static var defaults: Self {
      Self(maxFrameSize: 1 << 14, targetWindowSize: 8 * 1024 * 1024, authority: nil)
    }
  }

  /// A set of callbacks used for debugging purposes.
  ///
  /// The callbacks give you access to the underlying NIO `Channel` after gRPC's initializer has
  /// run for each `Channel`. These callbacks are intended for debugging purposes.
  ///
  /// - Important: You should be very careful when implementing these callbacks as they may have
  ///   unexpected side effects on your gRPC application.
  public struct ChannelDebuggingCallbacks: Sendable {
    /// A callback invoked with each new TCP connection.
    public var onCreateTCPConnection: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    /// A callback invoked with each new HTTP/2 stream.
    public var onCreateHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    public init(
      onCreateTCPConnection: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?,
      onCreateHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?
    ) {
      self.onCreateTCPConnection = onCreateTCPConnection
      self.onCreateHTTP2Stream = onCreateHTTP2Stream
    }

    /// Default values; no callbacks are set.
    public static var defaults: Self {
      Self(onCreateTCPConnection: nil, onCreateHTTP2Stream: nil)
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.Config.Connection {
  /// Flush coalescing batches together writes to reduce the overhead from syscalls.
  ///
  /// A channel handler intercepts flush events on the HTTP/2 connection channel and delays them
  /// until one of the following conditions is met:
  /// 1. ``maxFlushDelay`` has elapsed since a flush was first requested,
  /// 2. At least ``maxBytes`` bytes have been written since the previous flush, or
  /// 3. The channel becomes unwritable (i.e. the outbound buffer has hit the high-water mark).
  ///
  /// This means that under high load, writes naturally accumulate and are flushed together in
  /// fewer, larger batches. This reduces per-write overhead and typically improves both throughput
  /// and latency.
  ///
  /// Under low load there are fewer writes to coalesce so flushes are typically delayed by
  /// up to ``maxFlushDelay``. If your workload is latency-sensitive and low-throughput then
  /// disabling coalescing (by setting
  /// ``HTTP2ServerTransport/Config/Connection/flushCoalescing`` to `nil`) may be preferable.
  ///
  /// The default values (see ``defaults``) aim to provide a good balance for most workloads
  /// without adding significant latency.
  @available(gRPCSwiftNIOTransport 2.8, *)
  public struct FlushCoalescing: Sendable, Hashable {
    /// The maximum delay between a flush being requested and it being performed.
    public var maxFlushDelay: Duration

    /// The number of bytes to buffer before a flush is emitted, regardless of the delay.
    public var maxBytes: Int

    /// Creates a new flush coalescing configuration.
    ///
    /// - SeeAlso: ``defaults``.
    public init(maxFlushDelay: Duration, maxBytes: Int) {
      self.maxFlushDelay = maxFlushDelay
      self.maxBytes = maxBytes
    }

    /// Default values. The max flush delay is 100μs and the max bytes is 64KiB.
    public static var defaults: Self {
      Self(maxFlushDelay: .microseconds(100), maxBytes: 64 * 1024)
    }
  }
}
