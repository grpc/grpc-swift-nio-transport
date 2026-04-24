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
internal import NIOHTTP2

/// A namespace for the HTTP/2 server transport.
@available(gRPCSwiftNIOTransport 2.0, *)
public enum HTTP2ServerTransport: Sendable {}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport {
  /// A namespace for HTTP/2 server transport configuration.
  public enum Config: Sendable {}
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.Config {
  public struct Compression: Sendable, Hashable {
    /// Compression algorithms enabled for inbound messages.
    ///
    /// - Note: `CompressionAlgorithm.none` is always supported, even if it isn't set here.
    public var enabledAlgorithms: CompressionAlgorithmSet

    /// Creates a new compression configuration.
    ///
    /// - SeeAlso: ``defaults``.
    public init(enabledAlgorithms: CompressionAlgorithmSet) {
      self.enabledAlgorithms = enabledAlgorithms
    }

    /// Default values, compression is disabled.
    public static var defaults: Self {
      Self(enabledAlgorithms: .none)
    }
  }

  public struct Keepalive: Sendable, Hashable {
    /// The amount of time to wait after reading data before sending a keepalive ping.
    public var time: Duration

    /// The amount of time the server has to respond to a keepalive ping before the connection is closed.
    public var timeout: Duration

    /// Configuration for how the server enforces client keepalive.
    public var clientBehavior: ClientKeepaliveBehavior

    /// Creates a new keepalive configuration.
    public init(
      time: Duration,
      timeout: Duration,
      clientBehavior: ClientKeepaliveBehavior
    ) {
      self.time = time
      self.timeout = timeout
      self.clientBehavior = clientBehavior
    }

    /// Default values. The time after reading data a ping should be sent defaults to 2 hours, the timeout for
    /// keepalive pings defaults to 20 seconds, pings are not permitted when no calls are in progress, and
    /// the minimum allowed interval for clients to send pings defaults to 5 minutes.
    public static var defaults: Self {
      Self(
        time: .seconds(2 * 60 * 60),  // 2 hours
        timeout: .seconds(20),
        clientBehavior: .defaults
      )
    }
  }

  public struct ClientKeepaliveBehavior: Sendable, Hashable {
    /// The minimum allowed interval the client is allowed to send keep-alive pings.
    /// Pings more frequent than this interval count as 'strikes' and the connection is closed if there are
    /// too many strikes.
    public var minPingIntervalWithoutCalls: Duration

    /// Whether the server allows the client to send keepalive pings when there are no calls in progress.
    public var allowWithoutCalls: Bool

    /// Creates a new configuration for permitted client keepalive behavior.
    public init(
      minPingIntervalWithoutCalls: Duration,
      allowWithoutCalls: Bool
    ) {
      self.minPingIntervalWithoutCalls = minPingIntervalWithoutCalls
      self.allowWithoutCalls = allowWithoutCalls
    }

    /// Default values. The time after reading data a ping should be sent defaults to 2 hours, the timeout for
    /// keepalive pings defaults to 20 seconds, pings are not permitted when no calls are in progress, and
    /// the minimum allowed interval for clients to send pings defaults to 5 minutes.
    public static var defaults: Self {
      Self(minPingIntervalWithoutCalls: .seconds(5 * 60), allowWithoutCalls: false)
    }
  }

  public struct Connection: Sendable, Hashable {
    /// The maximum amount of time a connection may exist before being gracefully closed.
    public var maxAge: Duration?

    /// The maximum amount of time that the connection has to close gracefully.
    public var maxGraceTime: Duration?

    /// The maximum amount of time a connection may be idle before it's closed.
    public var maxIdleTime: Duration?

    /// Configuration for keepalive used to detect broken connections.
    ///
    /// - SeeAlso: gRFC A8 for client side keepalive, and gRFC A9 for server connection management.
    public var keepalive: Keepalive

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
    public init(
      maxAge: Duration?,
      maxGraceTime: Duration?,
      maxIdleTime: Duration?,
      keepalive: Keepalive
    ) {
      self.init(
        maxAge: maxAge,
        maxGraceTime: maxGraceTime,
        maxIdleTime: maxIdleTime,
        keepalive: keepalive,
        flushCoalescing: nil
      )
    }

    @available(gRPCSwiftNIOTransport 2.8, *)
    private init(
      maxAge: Duration?,
      maxGraceTime: Duration?,
      maxIdleTime: Duration?,
      keepalive: Keepalive,
      flushCoalescing: FlushCoalescing?
    ) {
      self.maxAge = maxAge
      self.maxGraceTime = maxGraceTime
      self.maxIdleTime = maxIdleTime
      self.keepalive = keepalive
      self.flushCoalescing = flushCoalescing
    }

    /// Default values. The max connection age, max grace time, and max idle time default to
    /// `nil` (i.e. infinite). See ``HTTP2ServerTransport/Config/Keepalive/defaults`` for keepalive
    /// defaults. Flush coalescing is enabled with default values.
    public static var defaults: Self {
      Self(
        maxAge: nil,
        maxGraceTime: nil,
        maxIdleTime: nil,
        keepalive: .defaults,
        flushCoalescing: .defaults
      )
    }
  }

  public struct HTTP2: Sendable, Hashable {
    /// The maximum frame size to be used in an HTTP/2 connection.
    public var maxFrameSize: Int

    /// The target window size for this connection.
    ///
    /// - Note: This will also be set as the initial window size for the connection.
    public var targetWindowSize: Int

    /// The number of concurrent streams on the HTTP/2 connection.
    public var maxConcurrentStreams: Int?

    public init(
      maxFrameSize: Int,
      targetWindowSize: Int,
      maxConcurrentStreams: Int?
    ) {
      self.maxFrameSize = maxFrameSize
      self.targetWindowSize = targetWindowSize
      self.maxConcurrentStreams = maxConcurrentStreams
    }

    /// Default values. The max frame size defaults to 2^14, the target window size defaults to 2^16-1, and
    /// the max concurrent streams default to infinite.
    public static var defaults: Self {
      Self(
        maxFrameSize: 1 << 14,
        targetWindowSize: (1 << 16) - 1,
        maxConcurrentStreams: nil
      )
    }
  }

  public struct RPC: Sendable, Hashable {
    /// The maximum request payload size.
    public var maxRequestPayloadSize: Int

    public init(maxRequestPayloadSize: Int) {
      self.maxRequestPayloadSize = maxRequestPayloadSize
    }

    /// Default values. Maximum request payload size defaults to 4MiB.
    public static var defaults: Self {
      Self(maxRequestPayloadSize: 4 * 1024 * 1024)
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
    /// A callback invoked when the server starts listening for new TCP connections.
    public var onBindTCPListener: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    /// A callback invoked with each new accepted TPC connection.
    public var onAcceptTCPConnection: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    /// A callback invoked with each accepted HTTP/2 stream.
    public var onAcceptHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    public init(
      onBindTCPListener: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?,
      onAcceptTCPConnection: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?,
      onAcceptHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?
    ) {
      self.onBindTCPListener = onBindTCPListener
      self.onAcceptTCPConnection = onAcceptTCPConnection
      self.onAcceptHTTP2Stream = onAcceptHTTP2Stream
    }

    /// Default values; no callbacks are set.
    public static var defaults: Self {
      Self(onBindTCPListener: nil, onAcceptTCPConnection: nil, onAcceptHTTP2Stream: nil)
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ServerTransport.Config.Connection {
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
