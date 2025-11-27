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

public import NIOCore

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.WrappedChannel {
  public struct Config: Sendable {
    /// Configuration for HTTP/2 connections.
    public var http2: HTTP2ClientTransport.Config.HTTP2

    /// Configuration for connection management.
    public var connection: HTTP2ClientTransport.Config.Connection

    /// Compression configuration.
    public var compression: HTTP2ClientTransport.Config.Compression

    /// Channel callbacks for debugging.
    public var channelDebuggingCallbacks: ChannelDebuggingCallbacks

    /// Creates a new connection configuration.
    ///
    /// - Parameters:
    ///   - http2: HTTP2 configuration.
    ///   - connection: Connection configuration.
    ///   - compression: Compression configuration.
    ///   - channelDebuggingCallbacks: Channel callbacks for debugging.
    ///
    /// - SeeAlso: ``defaults(_:)`` and ``defaults``.
    public init(
      http2: HTTP2ClientTransport.Config.HTTP2,
      connection: HTTP2ClientTransport.Config.Connection,
      compression: HTTP2ClientTransport.Config.Compression,
      channelDebuggingCallbacks: ChannelDebuggingCallbacks
    ) {
      self.http2 = http2
      self.connection = connection
      self.compression = compression
      self.channelDebuggingCallbacks = channelDebuggingCallbacks
    }

    /// Default configuration.
    public static var defaults: Self {
      Self.defaults { _ in }
    }

    /// Default values.
    ///
    /// - Parameters:
    ///   - configure: A closure which allows you to modify the defaults before returning them.
    public static func defaults(_ configure: (inout Self) -> Void) -> Self {
      var config = Self(
        http2: .defaults,
        connection: .defaults,
        compression: .defaults,
        channelDebuggingCallbacks: .defaults
      )
      configure(&config)
      return config
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2ClientTransport.WrappedChannel.Config {
  /// Callbacks used for debugging purposes.
  ///
  /// The callbacks give you access to the underlying NIO `Channel` after gRPC's initializer has
  /// run for each `Channel`. These callbacks are intended for debugging purposes.
  ///
  /// - Important: You should be very careful when implementing these callbacks as they may have
  ///   unexpected side effects on your gRPC application.
  public struct ChannelDebuggingCallbacks: Sendable {
    /// A callback invoked with each new HTTP/2 stream.
    public var onCreateHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?

    public init(
      onCreateHTTP2Stream: (@Sendable (_ channel: any Channel) -> EventLoopFuture<Void>)?
    ) {
      self.onCreateHTTP2Stream = onCreateHTTP2Stream
    }

    /// Default values; no callbacks are set.
    public static var defaults: Self {
      Self(onCreateHTTP2Stream: nil)
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension GRPCChannel.Config {
  init(_ config: HTTP2ClientTransport.WrappedChannel.Config) {
    self.init(
      http2: config.http2,
      // This (and the resolver backoff) won't be used, the channel is already connected and can
      // never reconnect.
      backoff: .defaults,
      resolverBackoff: .defaults,
      connection: config.connection,
      compression: config.compression
    )
  }
}
