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
import NIOEmbedded
import NIOHTTP2
import Testing

struct ClientConnectionHandlerTests {
  @Test("Connection closed after max idle time")
  func maxIdleTime() throws {
    let connection = try Connection(maxIdleTime: .minutes(5))
    try connection.activate()

    // Write the initial settings to ready the connection.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Idle with no streams open we should:
    // - read out a closing event,
    // - write a GOAWAY frame,
    // - close.
    connection.loop.advanceTime(by: .minutes(5))

    #expect(try connection.readEvent() == .closing(.idle))

    let frame = try #require(try connection.readFrame())
    #expect(frame.streamID == .rootStream)
    let (lastStreamID, error, data) = try #require(frame.payload.goAway)
    #expect(lastStreamID == .rootStream)
    #expect(error == .noError)
    #expect(data == ByteBuffer(string: "idle"))

    try connection.waitUntilClosed()
  }

  @Test("Connection closed after max idle time with open streams")
  func maxIdleTimeWhenOpenStreams() throws {
    let connection = try Connection(maxIdleTime: .minutes(5))
    try connection.activate()

    // Open a stream, the idle timer should be cancelled.
    connection.streamOpened(1)

    // Advance by the idle time, nothing should happen.
    connection.loop.advanceTime(by: .minutes(5))
    #expect(try connection.readEvent() == nil)
    #expect(try connection.readFrame() == nil)

    // Close the stream, the idle timer should begin again.
    connection.streamClosed(1)
    connection.loop.advanceTime(by: .minutes(5))
    let frame = try #require(try connection.readFrame())
    let (lastStreamID, error, data) = try #require(frame.payload.goAway)
    #expect(lastStreamID == .rootStream)
    #expect(error == .noError)
    #expect(data == ByteBuffer(string: "idle"))

    try connection.waitUntilClosed()
  }

  @Test("Connection closed after keepalive with open streams")
  func keepaliveWithOpenStreams() throws {
    let connection = try Connection(keepaliveTime: .minutes(1), keepaliveTimeout: .seconds(10))
    try connection.activate()

    // Write the initial settings to ready the connection.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Open a stream so keep-alive starts.
    connection.streamOpened(1)

    for _ in 0 ..< 10 {
      // Advance time, a PING should be sent, ACK it.
      connection.loop.advanceTime(by: .minutes(1))
      let frame1 = try #require(try connection.readFrame())
      #expect(frame1.streamID == .rootStream)
      let (data, ack) = try #require(frame1.payload.ping)
      #expect(!ack)
      try connection.ping(data: data, ack: true)

      #expect(try connection.readFrame() == nil)
    }

    // Close the stream, keep-alive pings should stop.
    connection.streamClosed(1)
    connection.loop.advanceTime(by: .minutes(1))
    #expect(try connection.readFrame() == nil)
  }

  @Test("Connection closed after keepalive with no open streams")
  func keepaliveWithNoOpenStreams() throws {
    let connection = try Connection(keepaliveTime: .minutes(1), allowKeepaliveWithoutCalls: true)
    try connection.activate()

    // Write the initial settings to ready the connection.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    for _ in 0 ..< 10 {
      // Advance time, a PING should be sent, ACK it.
      connection.loop.advanceTime(by: .minutes(1))
      let frame1 = try #require(try connection.readFrame())
      #expect(frame1.streamID == .rootStream)
      let (data, ack) = try #require(frame1.payload.ping)
      #expect(!ack)
      try connection.ping(data: data, ack: true)

      #expect(try connection.readFrame() == nil)
    }
  }

  @Test("Connection closed after keepalive with open streams and timeout")
  func keepaliveWithOpenStreamsTimingOut() throws {
    let connection = try Connection(keepaliveTime: .minutes(1), keepaliveTimeout: .seconds(10))
    try connection.activate()

    // Write the initial settings to ready the connection.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Open a stream so keep-alive starts.
    connection.streamOpened(1)

    // Advance time, a PING should be sent, don't ACK it.
    connection.loop.advanceTime(by: .minutes(1))
    let frame1 = try #require(try connection.readFrame())
    #expect(frame1.streamID == .rootStream)
    let (_, ack) = try #require(frame1.payload.ping)
    #expect(!ack)

    // Advance time by the keep alive timeout. We should:
    // - read a connection event
    // - read out a GOAWAY frame
    // - be closed
    connection.loop.advanceTime(by: .seconds(10))

    #expect(try connection.readEvent() == .closing(.keepaliveExpired))

    let frame2 = try #require(try connection.readFrame())
    #expect(frame2.streamID == .rootStream)
    let (lastStreamID, error, data) = try #require(frame2.payload.goAway)
    #expect(lastStreamID == .rootStream)
    #expect(error == .noError)
    #expect(data == ByteBuffer(string: "keepalive_expired"))

    // Doesn't wait for streams to close: the connection is bad.
    try connection.waitUntilClosed()
  }

  @Test("Received PING frames are ignored")
  func pingsAreIgnored() throws {
    let connection = try Connection()
    try connection.activate()

    // PING frames without ack set should be ignored, we rely on the HTTP/2 handler replying to them.
    try connection.ping(data: HTTP2PingData(), ack: false)
    #expect(try connection.readFrame() == nil)
  }

  @Test("Receiving GOAWAY results in close event")
  func receiveGoAway() throws {
    let connection = try Connection()
    try connection.activate()

    try connection.goAway(
      lastStreamID: 0,
      errorCode: .enhanceYourCalm,
      opaqueData: ByteBuffer(string: "too_many_pings")
    )

    // Should read out an event and close (because there are no open streams).
    #expect(try connection.readEvent() == .closing(.goAway(.enhanceYourCalm, "too_many_pings")))
    try connection.waitUntilClosed()
  }

  @Test("Receiving GOAWAY with no open streams")
  func receiveGoAwayWithOpenStreams() throws {
    let connection = try Connection()
    try connection.activate()

    connection.streamOpened(1)
    connection.streamOpened(2)
    connection.streamOpened(3)

    try connection.goAway(lastStreamID: .maxID, errorCode: .noError)

    // Should read out an event.
    #expect(try connection.readEvent() == .closing(.goAway(.noError, "")))

    // Close streams so the connection can close.
    connection.streamClosed(1)
    connection.streamClosed(2)
    connection.streamClosed(3)
    try connection.waitUntilClosed()
  }

  @Test("Receiving GOAWAY with no error and then GOAWAY with protoco error")
  func goAwayWithNoErrorThenGoAwayWithProtocolError() throws {
    let connection = try Connection()
    try connection.activate()

    connection.streamOpened(1)
    connection.streamOpened(2)
    connection.streamOpened(3)

    try connection.goAway(lastStreamID: .maxID, errorCode: .noError)
    // Should read out an event.
    #expect(try connection.readEvent() == .closing(.goAway(.noError, "")))

    // Upgrade the close from graceful to 'error'.
    try connection.goAway(lastStreamID: .maxID, errorCode: .protocolError)
    // Should read out an event and the connection will be closed without waiting for notification
    // from existing streams.
    #expect(try connection.readEvent() == .closing(.goAway(.protocolError, "")))
    try connection.waitUntilClosed()
  }

  @Test("Outbound graceful close")
  func outboundGracefulClose() throws {
    let connection = try Connection()
    try connection.activate()

    connection.streamOpened(1)
    let closed = connection.closeGracefully()
    #expect(try connection.readEvent() == .closing(.initiatedLocally))
    connection.streamClosed(1)
    try closed.wait()
  }

  @Test("Receive initial SETTINGS")
  func receiveInitialSettings() throws {
    let connection = try Connection()
    try connection.activate()

    // Nothing yet.
    #expect(try connection.readEvent() == nil)

    // Write the initial settings.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Receiving another settings frame should be a no-op.
    try connection.settings([])
    #expect(try connection.readEvent() == nil)
  }

  @Test("Receive error when idle")
  func receiveErrorWhenIdle() throws {
    let connection = try Connection()
    try connection.activate()

    // Write the initial settings.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Write an error and close.
    let error = RPCError(code: .aborted, message: "")
    connection.channel.pipeline.fireErrorCaught(error)
    connection.channel.close(mode: .all, promise: nil)

    #expect(try connection.readEvent() == .closing(.unexpected(error, isIdle: true)))
  }

  @Test("Receive error when streams are open")
  func receiveErrorWhenStreamsAreOpen() throws {
    let connection = try Connection()
    try connection.activate()

    // Write the initial settings.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    // Open a stream.
    connection.streamOpened(1)

    // Write an error and close.
    let error = RPCError(code: .aborted, message: "")
    connection.channel.pipeline.fireErrorCaught(error)
    connection.channel.close(mode: .all, promise: nil)

    #expect(try connection.readEvent() == .closing(.unexpected(error, isIdle: false)))
  }

  @Test("Unexpected close while idle")
  func unexpectedCloseWhenIdle() throws {
    let connection = try Connection()
    try connection.activate()

    // Write the initial settings.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    connection.channel.close(mode: .all, promise: nil)
    #expect(try connection.readEvent() == .closing(.unexpected(nil, isIdle: true)))
  }

  @Test("Unexpected close when streams are open")
  func unexpectedCloseWhenStreamsAreOpen() throws {
    let connection = try Connection()
    try connection.activate()

    // Write the initial settings.
    try connection.settings([])
    #expect(try connection.readEvent() == .ready)

    connection.streamOpened(1)
    connection.channel.close(mode: .all, promise: nil)
    #expect(try connection.readEvent() == .closing(.unexpected(nil, isIdle: false)))
  }
}

extension ClientConnectionHandlerTests {
  struct Connection {
    let channel: EmbeddedChannel
    let streamDelegate: any NIOHTTP2StreamDelegate
    var loop: EmbeddedEventLoop {
      self.channel.embeddedEventLoop
    }

    init(
      maxIdleTime: TimeAmount? = nil,
      keepaliveTime: TimeAmount? = nil,
      keepaliveTimeout: TimeAmount? = nil,
      allowKeepaliveWithoutCalls: Bool = false
    ) throws {
      let loop = EmbeddedEventLoop()
      let handler = ClientConnectionHandler(
        eventLoop: loop,
        maxIdleTime: maxIdleTime,
        keepaliveTime: keepaliveTime,
        keepaliveTimeout: keepaliveTimeout,
        keepaliveWithoutCalls: allowKeepaliveWithoutCalls
      )

      self.streamDelegate = handler.http2StreamDelegate
      self.channel = EmbeddedChannel(handler: handler, loop: loop)
    }

    func activate() throws {
      try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
    }

    func streamOpened(_ id: HTTP2StreamID) {
      self.streamDelegate.streamCreated(id, channel: self.channel)
    }

    func streamClosed(_ id: HTTP2StreamID) {
      self.streamDelegate.streamClosed(id, channel: self.channel)
    }

    func goAway(
      lastStreamID: HTTP2StreamID,
      errorCode: HTTP2ErrorCode,
      opaqueData: ByteBuffer? = nil
    ) throws {
      let frame = HTTP2Frame(
        streamID: .rootStream,
        payload: .goAway(lastStreamID: lastStreamID, errorCode: errorCode, opaqueData: opaqueData)
      )

      try self.channel.writeInbound(frame)
    }

    func ping(data: HTTP2PingData, ack: Bool) throws {
      let frame = HTTP2Frame(streamID: .rootStream, payload: .ping(data, ack: ack))
      try self.channel.writeInbound(frame)
    }

    func settings(_ settings: [HTTP2Setting]) throws {
      let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
      try self.channel.writeInbound(frame)
    }

    func readFrame() throws -> HTTP2Frame? {
      return try self.channel.readOutbound(as: HTTP2Frame.self)
    }

    func readEvent() throws -> ClientConnectionEvent? {
      return try self.channel.readInbound(as: ClientConnectionEvent.self)
    }

    func waitUntilClosed() throws {
      self.channel.embeddedEventLoop.run()
      try self.channel.closeFuture.wait()
    }

    func closeGracefully() -> EventLoopFuture<Void> {
      let promise = self.channel.embeddedEventLoop.makePromise(of: Void.self)
      let event = ClientConnectionHandler.OutboundEvent.closeGracefully
      self.channel.pipeline.triggerUserOutboundEvent(event, promise: promise)
      return promise.futureResult
    }
  }
}
