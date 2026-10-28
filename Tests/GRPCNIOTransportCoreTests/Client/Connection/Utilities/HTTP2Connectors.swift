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

import GRPCCore
import GRPCNIOTransportCore
import NIOCore
import NIOHTTP2
import NIOPosix

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2Connector where Self == ThrowingConnector {
  /// A connector which throws the given error on a connect attempt.
  static func throwing(_ error: RPCError) -> Self {
    return ThrowingConnector(error: error)
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2Connector where Self == NeverConnector {
  /// A connector which fatal errors if a connect attempt is made.
  static var never: Self {
    NeverConnector()
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension HTTP2Connector where Self == NIOPosixConnector {
  /// A connector which uses NIOPosix to establish a connection.
  static func posix(
    maxIdleTime: TimeAmount? = nil,
    keepaliveTime: TimeAmount? = nil,
    keepaliveTimeout: TimeAmount? = nil,
    keepaliveWithoutCalls: Bool = false,
    dropPingAcks: Bool = false,
    rateLimits: HTTP2ClientTransport.Config.HTTP2.RateLimits = .defaults
  ) -> Self {
    return NIOPosixConnector(
      maxIdleTime: maxIdleTime,
      keepaliveTime: keepaliveTime,
      keepaliveTimeout: keepaliveTimeout,
      keepaliveWithoutCalls: keepaliveWithoutCalls,
      dropPingAcks: dropPingAcks,
      rateLimits: rateLimits
    )
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
struct ThrowingConnector: HTTP2Connector {
  private let error: RPCError

  init(error: RPCError) {
    self.error = error
  }

  func establishConnection(
    to address: GRPCNIOTransportCore.SocketAddress,
    sniServerHostname: String?
  ) async throws -> HTTP2Connection {
    throw self.error
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
struct NeverConnector: HTTP2Connector {
  func establishConnection(
    to address: GRPCNIOTransportCore.SocketAddress,
    sniServerHostname: String?
  ) async throws -> HTTP2Connection {
    fatalError("\(#function) called unexpectedly")
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
struct NIOPosixConnector: HTTP2Connector {
  private let eventLoopGroup: any EventLoopGroup
  private let config: GRPCChannel.Config
  private let dropPingAcks: Bool

  /// Creates a connector which configures connections with the gRPC client pipeline.
  init(
    eventLoopGroup: (any EventLoopGroup)? = nil,
    maxIdleTime: TimeAmount? = nil,
    keepaliveTime: TimeAmount? = nil,
    keepaliveTimeout: TimeAmount? = nil,
    keepaliveWithoutCalls: Bool = false,
    dropPingAcks: Bool = false,
    rateLimits: HTTP2ClientTransport.Config.HTTP2.RateLimits = .defaults
  ) {
    var connection = HTTP2ClientTransport.Config.Connection.defaults
    connection.maxIdleTime = maxIdleTime.map { Duration($0) }

    if let keepaliveTime {
      connection.keepalive = HTTP2ClientTransport.Config.Keepalive(
        time: Duration(keepaliveTime),
        timeout: Duration(keepaliveTimeout ?? .seconds(20)),
        allowWithoutCalls: keepaliveWithoutCalls
      )
    }

    // Flush immediately so that tests don't depend on the flush coalescing delay.
    connection.flushCoalescing = nil

    var http2 = HTTP2ClientTransport.Config.HTTP2.defaults
    http2.rateLimits = rateLimits

    self.eventLoopGroup = eventLoopGroup ?? .singletonMultiThreadedEventLoopGroup
    self.config = GRPCChannel.Config(
      http2: http2,
      backoff: .defaults,
      resolverBackoff: .defaults,
      connection: connection,
      compression: .defaults
    )
    self.dropPingAcks = dropPingAcks
  }

  func establishConnection(
    to address: GRPCNIOTransportCore.SocketAddress,
    sniServerHostname: String?
  ) async throws -> HTTP2Connection {
    return try await ClientBootstrap(group: self.eventLoopGroup).connect(to: address) { channel in
      channel.eventLoop.makeCompletedFuture {
        let sync = channel.pipeline.syncOperations
        let (asyncChannel, multiplexer) = try sync.configureGRPCClientPipeline(
          channel: channel,
          config: self.config
        )

        if self.dropPingAcks {
          let http2Handler = try sync.handler(type: NIOHTTP2Handler.self)
          try sync.addHandler(PingAckDropper(), position: .after(http2Handler))
        }

        return HTTP2Connection(
          channel: asyncChannel,
          multiplexer: multiplexer,
          isPlaintext: true,
          onCreateHTTP2Stream: nil
        )
      }
    }
  }

  /// Drops all acks for PING frames. This is useful to help trigger the keepalive timeout.
  final class PingAckDropper: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let frame = self.unwrapInboundIn(data)
      switch frame.payload {
      case .ping(_, ack: true):
        ()  // drop-it
      default:
        context.fireChannelRead(data)
      }
    }
  }
}
