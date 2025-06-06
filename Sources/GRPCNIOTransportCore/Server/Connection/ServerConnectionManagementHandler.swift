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

private import GRPCCore
package import NIOCore
package import NIOHTTP2
private import NIOTLS

/// A `ChannelHandler` which manages the lifecycle of a gRPC connection over HTTP/2.
///
/// This handler is responsible for managing several aspects of the connection. These include:
/// 1. Handling the graceful close of connections. When gracefully closing a connection the server
///    sends a GOAWAY frame with the last stream ID set to the maximum stream ID allowed followed by
///    a PING frame. On receipt of the PING frame the server sends another GOAWAY frame with the
///    highest ID of all streams which have been opened. After this, the handler closes the
///    connection once all streams are closed.
/// 2. Enforcing that graceful shutdown doesn't exceed a configured limit (if configured).
/// 3. Gracefully closing the connection once it reaches the maximum configured age (if configured).
/// 4. Gracefully closing the connection once it has been idle for a given period of time (if
///    configured).
/// 5. Periodically sending keep alive pings to the client (if configured) and closing the
///    connection if necessary.
/// 6. Policing pings sent by the client to ensure that the client isn't misconfigured to send
///    too many pings.
///
/// Some of the behaviours are described in:
/// - [gRFC A8](https://github.com/grpc/proposal/blob/0e1807a6e30a1a915c0dcadc873bca92b9fa9720/A8-client-side-keepalive.md), and
/// - [gRFC A9](https://github.com/grpc/proposal/blob/0e1807a6e30a1a915c0dcadc873bca92b9fa9720/A9-server-side-conn-mgt.md).
@available(gRPCSwiftNIOTransport 2.0, *)
package final class ServerConnectionManagementHandler: ChannelDuplexHandler {
  package typealias InboundIn = HTTP2Frame
  package typealias InboundOut = HTTP2Frame
  package typealias OutboundIn = HTTP2Frame
  package typealias OutboundOut = HTTP2Frame

  /// The `EventLoop` of the `Channel` this handler exists in.
  private let eventLoop: any EventLoop

  /// The timer used to gracefully close idle connections.
  private var maxIdleTimerHandler: Timer<MaxIdleTimerHandlerView>?

  /// The timer used to gracefully close old connections.
  private var maxAgeTimerHandler: Timer<MaxAgeTimerHandlerView>?

  /// The timer used to forcefully close a connection during a graceful close.
  /// The timer starts after the second GOAWAY frame has been sent.
  private var maxGraceTimerHandler: Timer<MaxGraceTimerHandlerView>?

  /// The timer used to send keep-alive pings.
  private var keepaliveTimerHandler: Timer<KeepaliveTimerHandlerView>?

  /// The timer used to detect keep alive timeouts, if keep-alive pings are enabled.
  private var keepaliveTimeoutHandler: Timer<KeepaliveTimeoutHandlerView>?

  /// Opaque data sent in keep alive pings.
  private let keepalivePingData: HTTP2PingData

  /// Whether a flush is pending.
  private var flushPending: Bool

  /// Whether `channelRead` has been called and `channelReadComplete` hasn't yet been called.
  /// Resets once `channelReadComplete` returns.
  private var inReadLoop: Bool

  /// The context of the channel this handler is in.
  private var context: ChannelHandlerContext?

  /// The current state of the connection.
  private var state: StateMachine

  /// The clock.
  private let clock: Clock

  /// Whether ALPN is required.
  /// If it is but the TLS handshake finished without negotiating a protocol, an error will be fired down the
  /// pipeline and the channel will be closed.
  private let requireALPN: Bool

  /// A clock providing the current time.
  ///
  /// This is necessary for testing where a manual clock can be used and advanced from the test.
  /// While NIO's `EmbeddedEventLoop` provides control over its view of time (and therefore any
  /// events scheduled on it) it doesn't offer a way to get the current time. This is usually done
  /// via `NIODeadline`.
  package enum Clock {
    case nio
    case manual(Manual)

    func now() -> NIODeadline {
      switch self {
      case .nio:
        return .now()
      case .manual(let clock):
        return clock.time
      }
    }

    package final class Manual {
      private(set) var time: NIODeadline

      package init() {
        self.time = .uptimeNanoseconds(0)
      }

      package func advance(by amount: TimeAmount) {
        self.time = self.time + amount
      }
    }
  }

  /// Stats about recently written frames. Used to determine whether to reset keep-alive state.
  package var frameStats: FrameStats

  package struct FrameStats {
    private(set) var didWriteHeadersOrData = false

    /// Mark that a HEADERS frame has been written.
    mutating func wroteHeaders() {
      self.didWriteHeadersOrData = true
    }

    /// Mark that DATA frame has been written.
    mutating func wroteData() {
      self.didWriteHeadersOrData = true
    }

    /// Resets the state such that no HEADERS or DATA frames have been written.
    mutating func reset() {
      self.didWriteHeadersOrData = false
    }
  }

  /// A synchronous view over this handler.
  package var syncView: SyncView {
    return SyncView(self)
  }

  /// A synchronous view over this handler.
  ///
  /// Methods on this view *must* be called from the same `EventLoop` as the `Channel` in which
  /// this handler exists.
  package struct SyncView {
    private let handler: ServerConnectionManagementHandler

    fileprivate init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    /// Notify the handler that the connection has received a flush event.
    package func connectionWillFlush() {
      // The handler can't rely on `flush(context:)` due to its expected position in the pipeline.
      // It's expected to be placed after the HTTP/2 handler (i.e. closer to the application) as
      // it needs to receive HTTP/2 frames. However, flushes from stream channels aren't sent down
      // the entire connection channel, instead they are sent from the point in the channel they
      // are multiplexed from (either the HTTP/2 handler or the HTTP/2 multiplexing handler,
      // depending on how multiplexing is configured).
      self.handler.eventLoop.assertInEventLoop()
      if self.handler.frameStats.didWriteHeadersOrData {
        self.handler.frameStats.reset()
        self.handler.state.resetKeepaliveState()
      }
    }

    /// Notify the handler that a HEADERS frame was written in the last write loop.
    package func wroteHeadersFrame() {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.frameStats.wroteHeaders()
    }

    /// Notify the handler that a DATA frame was written in the last write loop.
    package func wroteDataFrame() {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.frameStats.wroteData()
    }
  }

  /// Creates a new handler which manages the lifecycle of a connection.
  ///
  /// - Parameters:
  ///   - eventLoop: The `EventLoop` of the `Channel` this handler is placed in.
  ///   - maxIdleTime: The maximum amount time a connection may be idle for before being closed.
  ///   - maxAge: The maximum amount of time a connection may exist before being gracefully closed.
  ///   - maxGraceTime: The maximum amount of time that the connection has to close gracefully.
  ///   - keepaliveTime: The amount of time to wait after reading data before sending a keep-alive
  ///       ping.
  ///   - keepaliveTimeout: The amount of time the client has to reply after the server sends a
  ///       keep-alive ping to keep the connection open. The connection is closed if no reply
  ///       is received.
  ///   - allowKeepaliveWithoutCalls: Whether the server allows the client to send keep-alive pings
  ///       when there are no calls in progress.
  ///   - minPingIntervalWithoutCalls: The minimum allowed interval the client is allowed to send
  ///       keep-alive pings. Pings more frequent than this interval count as 'strikes' and the
  ///       connection is closed if there are too many strikes.
  ///   - clock: A clock providing the current time.
  package init(
    eventLoop: any EventLoop,
    maxIdleTime: TimeAmount?,
    maxAge: TimeAmount?,
    maxGraceTime: TimeAmount?,
    keepaliveTime: TimeAmount?,
    keepaliveTimeout: TimeAmount?,
    allowKeepaliveWithoutCalls: Bool,
    minPingIntervalWithoutCalls: TimeAmount,
    requireALPN: Bool,
    clock: Clock = .nio
  ) {
    self.eventLoop = eventLoop

    // Generate a random value to be used as keep alive ping data.
    let pingData = UInt64.random(in: .min ... .max)
    self.keepalivePingData = HTTP2PingData(withInteger: pingData)

    self.state = StateMachine(
      allowKeepaliveWithoutCalls: allowKeepaliveWithoutCalls,
      minPingReceiveIntervalWithoutCalls: minPingIntervalWithoutCalls,
      goAwayPingData: HTTP2PingData(withInteger: ~pingData)
    )

    self.flushPending = false
    self.inReadLoop = false
    self.clock = clock
    self.frameStats = FrameStats()

    self.requireALPN = requireALPN

    if let maxIdleTime {
      self.maxIdleTimerHandler = Timer(
        eventLoop: eventLoop,
        duration: maxIdleTime,
        repeating: false,
        handler: MaxIdleTimerHandlerView(self)
      )
    }
    if let maxAge {
      self.maxAgeTimerHandler = Timer(
        eventLoop: eventLoop,
        duration: maxAge,
        repeating: false,
        handler: MaxAgeTimerHandlerView(self)
      )
    }
    if let maxGraceTime {
      self.maxGraceTimerHandler = Timer(
        eventLoop: eventLoop,
        duration: maxGraceTime,
        repeating: false,
        handler: MaxGraceTimerHandlerView(self)
      )
    }
    if let keepaliveTime {
      let keepaliveTimeout = keepaliveTimeout ?? .seconds(20)
      // NOTE: The use of a non-repeating timer is deliberate for the server, and is different from the client.
      self.keepaliveTimerHandler = Timer(
        eventLoop: eventLoop,
        duration: keepaliveTime,
        repeating: false,
        handler: KeepaliveTimerHandlerView(self)
      )
      self.keepaliveTimeoutHandler = Timer(
        eventLoop: eventLoop,
        duration: keepaliveTimeout,
        repeating: false,
        handler: KeepaliveTimeoutHandlerView(self)
      )
    }
  }

  package func handlerAdded(context: ChannelHandlerContext) {
    assert(context.eventLoop === self.eventLoop)
    self.context = context
  }

  package func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
  }

  package func channelActive(context: ChannelHandlerContext) {
    self.maxAgeTimerHandler?.start()
    self.maxIdleTimerHandler?.start()
    self.keepaliveTimerHandler?.start()
    context.fireChannelActive()
  }

  package func channelInactive(context: ChannelHandlerContext) {
    self.maxIdleTimerHandler?.cancel()
    self.maxAgeTimerHandler = nil

    self.maxAgeTimerHandler?.cancel()
    self.maxAgeTimerHandler = nil

    self.maxGraceTimerHandler?.cancel()
    self.maxGraceTimerHandler = nil

    self.keepaliveTimerHandler?.cancel()
    self.keepaliveTimerHandler = nil

    self.keepaliveTimeoutHandler?.cancel()
    self.keepaliveTimeoutHandler = nil

    context.fireChannelInactive()
  }

  package func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let event as NIOHTTP2StreamCreatedEvent:
      self._streamCreated(event.streamID, channel: context.channel)

    case let event as StreamClosedEvent:
      self._streamClosed(event.streamID, channel: context.channel)

    case is ChannelShouldQuiesceEvent:
      self.initiateGracefulShutdown()

    case TLSUserEvent.handshakeCompleted(let negotiatedProtocol):
      if negotiatedProtocol == nil, self.requireALPN {
        // No ALPN protocol negotiated but it was required: fire an error and close the channel.
        context.fireErrorCaught(
          RPCError(
            code: .internalError,
            message: "ALPN resulted in no protocol being negotiated, but it was required."
          )
        )
        context.close(mode: .all, promise: nil)
      }

    default:
      ()
    }

    context.fireUserInboundEventTriggered(event)
  }

  package func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if self.closeConnectionOnError(error) {
      context.close(mode: .all, promise: nil)
    }
  }

  private func closeConnectionOnError(_ error: any Error) -> Bool {
    switch error {
    case is NIOHTTP2Errors.NoSuchStream:
      // In most cases this represents incorrect client behaviour. However, NIOHTTP2 currently
      // emits this error if a server receives a HEADERS frame for a new stream after having sent
      // a GOAWAY frame. This can happen when a client opening a stream races with a server
      // shutting down.
      //
      // This should be resolved in NIOHTTP2: https://github.com/apple/swift-nio-http2/issues/466
      //
      // Only close the connection if it's not already closing (as this is the state in which the
      // error can be safely ignored).
      return !self.state.isClosing

    case is NIOHTTP2Errors.StreamError:
      // Stream errors occur in streams, they are only propagated down the connection channel
      // pipeline for vestigial reasons.
      return false

    default:
      // Everything else is considered terminal for the connection until we know better.
      return true
    }
  }

  package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    self.inReadLoop = true

    // Any read data indicates that the connection is alive so cancel the keep-alive timers.
    self.keepaliveTimerHandler?.cancel()
    self.keepaliveTimeoutHandler?.cancel()

    let frame = self.unwrapInboundIn(data)
    switch frame.payload {
    case .ping(let data, let ack):
      if ack {
        self.handlePingAck(context: context, data: data)
      } else {
        self.handlePing(context: context, data: data)
      }

    default:
      ()  // Only interested in PING frames, ignore the rest.
    }

    context.fireChannelRead(data)
  }

  package func channelReadComplete(context: ChannelHandlerContext) {
    while self.flushPending {
      self.flushPending = false
      context.flush()
    }

    self.inReadLoop = false

    // Done reading: schedule the keep-alive timer.
    self.keepaliveTimerHandler?.start()

    context.fireChannelReadComplete()
  }

  package func flush(context: ChannelHandlerContext) {
    self.maybeFlush(context: context)
  }
}

// Timer handler views.
@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerConnectionManagementHandler {
  struct MaxIdleTimerHandlerView: @unchecked Sendable, NIOScheduledCallbackHandler {
    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.initiateGracefulShutdown()
    }
  }

  struct MaxAgeTimerHandlerView: @unchecked Sendable, NIOScheduledCallbackHandler {
    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.initiateGracefulShutdown()
    }
  }

  struct MaxGraceTimerHandlerView: @unchecked Sendable, NIOScheduledCallbackHandler {
    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.context?.close(promise: nil)
    }
  }

  struct KeepaliveTimerHandlerView: @unchecked Sendable, NIOScheduledCallbackHandler {
    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.keepaliveTimerFired()
    }
  }

  struct KeepaliveTimeoutHandlerView: @unchecked Sendable, NIOScheduledCallbackHandler {
    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
      self.handler.eventLoop.assertInEventLoop()
      self.handler.initiateGracefulShutdown()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerConnectionManagementHandler {
  package struct HTTP2StreamDelegate: @unchecked Sendable, NIOHTTP2StreamDelegate {
    // @unchecked is okay: the only methods do the appropriate event-loop dance.

    private let handler: ServerConnectionManagementHandler

    init(_ handler: ServerConnectionManagementHandler) {
      self.handler = handler
    }

    package func streamCreated(_ id: HTTP2StreamID, channel: any Channel) {
      if self.handler.eventLoop.inEventLoop {
        self.handler._streamCreated(id, channel: channel)
      } else {
        self.handler.eventLoop.execute {
          self.handler._streamCreated(id, channel: channel)
        }
      }
    }

    package func streamClosed(_ id: HTTP2StreamID, channel: any Channel) {
      if self.handler.eventLoop.inEventLoop {
        self.handler._streamClosed(id, channel: channel)
      } else {
        self.handler.eventLoop.execute {
          self.handler._streamClosed(id, channel: channel)
        }
      }
    }
  }

  package var http2StreamDelegate: HTTP2StreamDelegate {
    return HTTP2StreamDelegate(self)
  }

  private func _streamCreated(_ id: HTTP2StreamID, channel: any Channel) {
    // The connection isn't idle if a stream is open.
    self.maxIdleTimerHandler?.cancel()
    self.state.streamOpened(id)
  }

  private func _streamClosed(_ id: HTTP2StreamID, channel: any Channel) {
    guard let context = self.context else { return }

    switch self.state.streamClosed(id) {
    case .startIdleTimer:
      self.maxIdleTimerHandler?.start()
    case .close:
      // Defer closing until the next tick of the event loop.
      //
      // This point is reached because the server is shutting down gracefully and the stream count
      // has dropped to zero, meaning the connection is no longer required and can be closed.
      // However, the stream would've been closed by writing and flushing a frame with end stream
      // set. These are two distinct events in the channel pipeline. The HTTP/2 handler updates the
      // state machine when a frame is written, which in this case results in the stream closed
      // event which we're reacting to here.
      //
      // Importantly the HTTP/2 handler hasn't yet seen the flush event, so the bytes of the frame
      // with end-stream set - and potentially some other frames - are sitting in a buffer in the
      // HTTP/2 handler. If we close on this event loop tick then those frames will be dropped.
      // Delaying the close by a loop tick will allow the flush to happen before the close.
      let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
      context.eventLoop.execute {
        loopBound.value.close(mode: .all, promise: nil)
      }

    case .none:
      ()
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension ServerConnectionManagementHandler {
  private func maybeFlush(context: ChannelHandlerContext) {
    if self.inReadLoop {
      self.flushPending = true
    } else {
      context.flush()
    }
  }

  private func initiateGracefulShutdown() {
    guard let context = self.context else { return }
    context.eventLoop.assertInEventLoop()

    // Cancel any timers if initiating shutdown.
    self.maxIdleTimerHandler?.cancel()
    self.maxAgeTimerHandler?.cancel()
    self.keepaliveTimerHandler?.cancel()
    self.keepaliveTimeoutHandler?.cancel()

    switch self.state.startGracefulShutdown() {
    case .sendGoAwayAndPing(let pingData):
      // There's a time window between the server sending a GOAWAY frame and the client receiving
      // it. During this time the client may open new streams as it doesn't yet know about the
      // GOAWAY frame.
      //
      // The server therefore sends a GOAWAY with the last stream ID set to the maximum stream ID
      // and follows it with a PING frame. When the server receives the ack for the PING frame it
      // knows that the client has received the initial GOAWAY frame and that no more streams may
      // be opened. The server can then send an additional GOAWAY frame with a more representative
      // last stream ID.
      let goAway = HTTP2Frame(
        streamID: .rootStream,
        payload: .goAway(
          lastStreamID: .maxID,
          errorCode: .noError,
          opaqueData: nil
        )
      )

      let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false))

      context.write(self.wrapOutboundOut(goAway), promise: nil)
      context.write(self.wrapOutboundOut(ping), promise: nil)
      self.maybeFlush(context: context)

    case .none:
      ()  // Already shutting down.
    }
  }

  private func handlePing(context: ChannelHandlerContext, data: HTTP2PingData) {
    switch self.state.receivedPing(atTime: self.clock.now(), data: data) {
    case .enhanceYourCalmThenClose(let streamID):
      let goAway = HTTP2Frame(
        streamID: .rootStream,
        payload: .goAway(
          lastStreamID: streamID,
          errorCode: .enhanceYourCalm,
          opaqueData: context.channel.allocator.buffer(string: "too_many_pings")
        )
      )

      context.write(self.wrapOutboundOut(goAway), promise: nil)
      self.maybeFlush(context: context)

      // We must delay the channel close after sending the GOAWAY packet by a tick to make sure it
      // gets flushed and delivered to the client before the connection is closed.
      let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
      context.eventLoop.execute {
        loopBound.value.close(promise: nil)
      }

    case .sendAck:
      ()  // ACKs are sent by NIO's HTTP/2 handler, don't double ack.

    case .none:
      ()
    }
  }

  private func handlePingAck(context: ChannelHandlerContext, data: HTTP2PingData) {
    switch self.state.receivedPingAck(data: data) {
    case .sendGoAway(let streamID, let close):
      let goAway = HTTP2Frame(
        streamID: .rootStream,
        payload: .goAway(lastStreamID: streamID, errorCode: .noError, opaqueData: nil)
      )

      context.write(self.wrapOutboundOut(goAway), promise: nil)
      self.maybeFlush(context: context)

      if close {
        context.close(promise: nil)
      } else {
        // RPCs may have a grace period for finishing once the second GOAWAY frame has finished.
        // If this is set close the connection abruptly once the grace period passes.
        self.maxGraceTimerHandler?.start()
      }

    case .none:
      ()
    }
  }

  private func keepaliveTimerFired() {
    guard let context = self.context else { return }
    let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(self.keepalivePingData, ack: false))
    context.write(self.wrapInboundOut(ping), promise: nil)
    self.maybeFlush(context: context)

    // Schedule a timeout on waiting for the response.
    self.keepaliveTimeoutHandler?.start()
  }
}
