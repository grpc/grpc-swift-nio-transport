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
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import Testing
import XCTest

@testable import GRPCNIOTransportCore

@available(gRPCSwiftNIOTransport 2.0, *)
final class GRPCServerStreamHandlerTests: XCTestCase {
  private func makeServerStreamHandler(
    channel: any Channel,
    scheme: Scheme = .http,
    acceptedEncodings: CompressionAlgorithmSet = [],
    maxPayloadSize: Int = .max,
    descriptorPromise: EventLoopPromise<MethodDescriptor>? = nil,
    disableAssertions: Bool = false
  ) -> GRPCServerStreamHandler {
    let serverConnectionManagementHandler = ServerConnectionManagementHandler(
      eventLoop: channel.eventLoop,
      maxIdleTime: nil,
      maxAge: nil,
      maxGraceTime: nil,
      keepaliveTime: nil,
      keepaliveTimeout: nil,
      allowKeepaliveWithoutCalls: false,
      minPingIntervalWithoutCalls: .minutes(5),
      requireALPN: false
    )

    return GRPCServerStreamHandler(
      scheme: scheme,
      acceptedEncodings: acceptedEncodings,
      maxPayloadSize: maxPayloadSize,
      methodDescriptorPromise: descriptorPromise ?? channel.eventLoop.makePromise(),
      eventLoop: channel.eventLoop,
      connectionManagementHandler: serverConnectionManagementHandler.syncView,
      skipStateMachineAssertions: disableAssertions
    )
  }

  func testH2FramesAreIgnored() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    let framesToBeIgnored: [HTTP2Frame.FramePayload] = [
      .ping(.init(), ack: false),
      .goAway(lastStreamID: .rootStream, errorCode: .cancel, opaqueData: nil),
      .priority(
        HTTP2Frame.StreamPriorityData(exclusive: false, dependency: .rootStream, weight: 4)
      ),
      .settings(.ack),
      .pushPromise(.init(pushedStreamID: .maxID, headers: [:])),
      .windowUpdate(windowSizeIncrement: 4),
      .alternativeService(origin: nil, field: nil),
      .origin([]),
    ]

    for toBeIgnored in framesToBeIgnored {
      XCTAssertNoThrow(try channel.writeInbound(toBeIgnored))
      XCTAssertNil(try channel.readInbound(as: HTTP2Frame.FramePayload.self))
    }
  }

  func testClientInitialMetadataWithoutContentTypeResultsInRejectedRPC() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata without content-type
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we have sent a trailers-only response
    let writtenTrailersOnlyResponse = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(writtenTrailersOnlyResponse.headers, [":status": "415"])
    XCTAssertTrue(writtenTrailersOnlyResponse.endStream)
  }

  func testClientInitialMetadataWithoutMethodResultsInRejectedRPC() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata without :method
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we have sent a trailers-only response
    let writtenTrailersOnlyResponse = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenTrailersOnlyResponse.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.invalidArgument.rawValue),
        GRPCHTTP2Keys.grpcStatusMessage.rawValue:
          ":method header is expected to be present and have a value of \"POST\".",
      ]
    )
    XCTAssertTrue(writtenTrailersOnlyResponse.endStream)
  }

  func testClientInitialMetadataWithoutSchemeResultsInRejectedRPC() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata without :scheme
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we have sent a trailers-only response
    let writtenTrailersOnlyResponse = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenTrailersOnlyResponse.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.invalidArgument.rawValue),
        GRPCHTTP2Keys.grpcStatusMessage.rawValue:
          ":scheme header must be present and one of \"http\" or \"https\".",
      ]
    )
    XCTAssertTrue(writtenTrailersOnlyResponse.endStream)
  }

  func testClientInitialMetadataWithoutPathResultsInRejectedRPC() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata without :path
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we have sent a trailers-only response
    let writtenTrailersOnlyResponse = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenTrailersOnlyResponse.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.invalidArgument.rawValue),
        GRPCHTTP2Keys.grpcStatusMessage.rawValue: "No :path header has been set.",
      ]
    )
    XCTAssertTrue(writtenTrailersOnlyResponse.endStream)
  }

  func testNotAcceptedEncodingResultsInRejectedRPC() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
      GRPCHTTP2Keys.encoding.rawValue: "deflate",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we have sent a trailers-only response
    let writtenTrailersOnlyResponse = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenTrailersOnlyResponse.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.unimplemented.rawValue),
        GRPCHTTP2Keys.grpcStatusMessage.rawValue:
          "deflate compression is not supported; supported algorithms are listed in grpc-accept-encoding",
        GRPCHTTP2Keys.acceptEncoding.rawValue: "identity",
      ]
    )
    XCTAssertTrue(writtenTrailersOnlyResponse.endStream)
  }

  func testOverMaximumPayloadSize() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel, maxPayloadSize: 1)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let headers: HPACKHeaders = [
      "some-custom-header": "some-custom-value"
    ]
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: headers)
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Make sure we wrote back the initial metadata
    let writtenHeaders = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        "some-custom-header": "some-custom-value",
      ]
    )

    // Receive client's message
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let clientDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeInbound(HTTP2Frame.FramePayload.data(clientDataPayload))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Failed to decode message")
    }

    // Make sure we haven't sent a response back and that we didn't read the received message
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertNil(try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self))
  }

  func testClientEndsStream() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel, disableAssertions: true)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata with end stream set
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata, endStream: true))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let headers: HPACKHeaders = [
      "some-custom-header": "some-custom-value"
    ]
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: headers)
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Make sure we wrote back the initial metadata
    let writtenHeaders = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        "some-custom-header": "some-custom-value",
      ]
    )

    // We should throw if the client sends another message, since it's closed the stream already.
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let clientDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeInbound(HTTP2Frame.FramePayload.data(clientDataPayload))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testNormalFlow() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel, disableAssertions: true)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let headers: HPACKHeaders = [
      "some-custom-header": "some-custom-value"
    ]
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: headers)
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Make sure we wrote back the initial metadata
    let writtenHeaders = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        "some-custom-header": "some-custom-value",
      ]
    )

    // Receive client's message
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let clientDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame.FramePayload.data(clientDataPayload)))

    // Make sure we haven't sent back an error response, and that we read the message properly
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 0, count: 42))
    )

    // Write back response
    let serverDataPayload = RPCResponsePart.message(GRPCNIOTransportBytes(repeating: 1, count: 42))
    XCTAssertNoThrow(try channel.writeOutbound(serverDataPayload))

    // Make sure we wrote back the right message
    let writtenMessage = try channel.assertReadDataOutbound()

    var expectedBuffer = ByteBuffer()
    expectedBuffer.writeInteger(UInt8(0))  // not compressed
    expectedBuffer.writeInteger(UInt32(42))  // message length
    expectedBuffer.writeRepeatingByte(1, count: 42)  // message
    XCTAssertEqual(writtenMessage.data, .byteBuffer(expectedBuffer))

    // Send back status to end RPC
    let trailers = RPCResponsePart<GRPCNIOTransportBytes>.status(
      .init(code: .dataLoss, message: "Test data loss"),
      ["custom-header": "custom-value"]
    )
    XCTAssertNoThrow(try channel.writeOutbound(trailers))

    // Make sure we wrote back the status and trailers
    let writtenStatus = try channel.assertReadHeadersOutbound()

    XCTAssertTrue(writtenStatus.endStream)
    XCTAssertEqual(
      writtenStatus.headers,
      [
        GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.dataLoss.rawValue),
        GRPCHTTP2Keys.grpcStatusMessage.rawValue: "Test data loss",
        "custom-header": "custom-value",
      ]
    )

    // Try writing and assert it throws to make sure we don't allow writes
    // after closing.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(trailers)
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testReceiveMessageSplitAcrossMultipleBuffers() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let headers: HPACKHeaders = [
      "some-custom-header": "some-custom-value"
    ]
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: headers)
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Make sure we wrote back the initial metadata
    let writtenHeaders = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.status.rawValue: "200",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        "some-custom-header": "some-custom-value",
      ]
    )

    // Receive client's first message
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeInteger(UInt32(30))  // message length
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(0, count: 10)  // first part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(1, count: 10)  // second part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(2, count: 10)  // third part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )

    var expected = ByteBuffer()
    expected.writeRepeatingByte(0, count: 10)
    expected.writeRepeatingByte(1, count: 10)
    expected.writeRepeatingByte(2, count: 10)
    // Make sure we haven't sent back an error response, and that we read the message properly
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart.message(GRPCNIOTransportBytes(expected))
    )
  }

  func testReceiveMultipleHeaders() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)
    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    try channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata)))
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Receive them again. Should be a protocol violation.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    ) { error in
      XCTAssertEqual(error.code, .unavailable)
      XCTAssertEqual(error.message, "Stream unexpectedly closed.")
    }
    let payload = try XCTUnwrap(channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    switch payload {
    case .rstStream(let errorCode):
      XCTAssertEqual(errorCode, .protocolError)
    default:
      XCTFail("Expected RST_STREAM, got \(payload)")
    }
  }

  func testSendMultipleMessagesInSingleBuffer() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let headers: HPACKHeaders = [
      "some-custom-header": "some-custom-value"
    ]
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: headers)
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Read out the metadata
    _ = try channel.readOutbound(as: HTTP2Frame.FramePayload.self)

    // This is where this test actually begins. We want to write two messages
    // without flushing, and make sure that no messages are sent down the pipeline
    // until we flush. Once we flush, both messages should be sent in the same ByteBuffer.

    // Write back first message and make sure nothing's written in the channel.
    XCTAssertNoThrow(
      channel.write(RPCResponsePart.message(GRPCNIOTransportBytes(repeating: 1, count: 4)))
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Write back second message and make sure nothing's written in the channel.
    XCTAssertNoThrow(
      channel.write(RPCResponsePart.message(GRPCNIOTransportBytes(repeating: 2, count: 4)))
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Now flush and check we *do* write the data.
    channel.flush()

    let writtenMessage = try channel.assertReadDataOutbound()

    // Make sure both messages have been framed together in the ByteBuffer.
    XCTAssertEqual(
      writtenMessage.data,
      .byteBuffer(
        .init(bytes: [
          // First message
          0,  // Compression disabled
          0, 0, 0, 4,  // Message length
          1, 1, 1, 1,  // First message data

          // Second message
          0,  // Compression disabled
          0, 0, 0, 4,  // Message length
          2, 2, 2, 2,  // Second message data
        ])
      )
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
  }

  func testMessageAndStatusAreNotReordered() throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerStreamHandler(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Write back server's initial metadata
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata(
      Metadata(headers: [:])
    )
    XCTAssertNoThrow(try channel.writeOutbound(serverInitialMetadata))

    // Read out the metadata
    _ = try channel.readOutbound(as: HTTP2Frame.FramePayload.self)

    // This is where this test actually begins. We want to write a message followed
    // by status and trailers, and only flush after both writes.
    // Because messages are buffered and potentially bundled together in a single
    // ByteBuffer by the GPRCMessageFramer, we want to make sure that the status
    // and trailers won't be written before the messages.

    // Write back message and make sure nothing's written in the channel.
    XCTAssertNoThrow(
      channel.write(RPCResponsePart.message(GRPCNIOTransportBytes(repeating: 1, count: 4)))
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Write status + metadata and make sure nothing's written.
    XCTAssertNoThrow(
      channel.write(
        RPCResponsePart<GRPCNIOTransportBytes>.status(.init(code: .ok, message: ""), [:])
      )
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Now flush and check we *do* write the data in the right order: message first,
    // trailers second.
    channel.flush()

    let writtenMessage = try channel.assertReadDataOutbound()

    // Make sure we first get message.
    XCTAssertEqual(
      writtenMessage.data,
      .byteBuffer(
        .init(bytes: [
          // First message
          0,  // Compression disabled
          0, 0, 0, 4,  // Message length
          1, 1, 1, 1,  // First message data
        ])
      )
    )
    XCTAssertFalse(writtenMessage.endStream)

    // Make sure we get trailers.
    let writtenTrailers = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(writtenTrailers.headers, ["grpc-status": "0"])
    XCTAssertTrue(writtenTrailers.endStream)

    // Make sure we get nothing else.
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
  }

  func testMethodDescriptorPromiseSucceeds() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(channel: channel, descriptorPromise: promise)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    XCTAssertEqual(
      try promise.futureResult.wait(),
      MethodDescriptor(fullyQualifiedService: "SomeService", method: "SomeMethod")
    )
  }

  func testMethodDescriptorPromiseIsFailedWhenHandlerRemoved() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(channel: channel, descriptorPromise: promise)
    try channel.pipeline.syncOperations.addHandler(handler)
    try channel.pipeline.syncOperations.removeHandler(handler).wait()

    XCTAssertThrowsError(
      ofType: RPCError.self,
      try promise.futureResult.wait()
    ) { error in
      XCTAssertEqual(error.code, .unavailable)
      XCTAssertEqual(error.message, "RPC stream was closed before we got any Metadata.")
    }
  }

  func testMethodDescriptorPromiseIsFailedIfRPCRejected() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(channel: channel, descriptorPromise: promise)
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/not-valid-contenttype",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    XCTAssertThrowsError(
      ofType: RPCError.self,
      try promise.futureResult.wait()
    ) { error in
      XCTAssertEqual(error.code, .unavailable)
      XCTAssertEqual(error.message, "RPC was rejected.")
    }
  }

  func testUnexpectedStreamClose_ErrorFired() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(
      channel: channel,
      descriptorPromise: promise,
      disableAssertions: true
    )
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // An error is fired down the pipeline
    let thrownError = ChannelError.connectTimeout(.milliseconds(100))
    channel.pipeline.fireErrorCaught(thrownError)

    // The server handler simply forwards the error.
    XCTAssertThrowsError(
      ofType: type(of: thrownError),
      try channel.throwIfErrorCaught()
    ) { error in
      XCTAssertEqual(error, thrownError)
    }

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCResponsePart<GRPCNIOTransportBytes>.metadata(Metadata()))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testUnexpectedStreamClose_ChannelInactive() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(
      channel: channel,
      descriptorPromise: promise,
      disableAssertions: true
    )
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // Channel becomes inactive
    channel.pipeline.fireChannelInactive()

    // The server handler fires an error
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.throwIfErrorCaught()
    ) { error in
      XCTAssertEqual(error.code, .unavailable)
      XCTAssertEqual(error.message, "Stream unexpectedly closed.")
    }

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCResponsePart<GRPCNIOTransportBytes>.metadata(Metadata()))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testUnexpectedStreamClose_ResetStreamFrame() throws {
    let channel = EmbeddedChannel()
    let promise = channel.eventLoop.makePromise(of: MethodDescriptor.self)
    let handler = self.makeServerStreamHandler(
      channel: channel,
      descriptorPromise: promise,
      disableAssertions: true
    )
    try channel.pipeline.syncOperations.addHandler(handler)

    // Receive client's initial metadata
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
      )
    )

    // Make sure we haven't sent back an error response, and that we read the initial metadata
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))
    XCTAssertEqual(
      try channel.readInbound(as: RPCRequestPart<GRPCNIOTransportBytes>.self),
      RPCRequestPart<GRPCNIOTransportBytes>.metadata(Metadata(headers: clientInitialMetadata))
    )

    // We receive RST_STREAM frame
    // Assert the server handler fires an error
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeInbound(
        HTTP2Frame.FramePayload.rstStream(.internalError)
      )
    ) { error in
      XCTAssertEqual(error.code, .unavailable)
      XCTAssertEqual(error.message, "Stream unexpectedly closed: a RST_STREAM frame was received.")
    }

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCResponsePart<GRPCNIOTransportBytes>.metadata([:]))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

}

struct ServerStreamHandlerTests {
  @available(gRPCSwiftNIOTransport 2.0, *)
  struct ConnectionAndStreamHandlers {
    let streamHandler: GRPCServerStreamHandler
    let connectionHandler: ServerConnectionManagementHandler
  }

  @available(gRPCSwiftNIOTransport 2.0, *)
  private func makeServerConnectionAndStreamHandlers(
    channel: any Channel,
    scheme: Scheme = .http,
    acceptedEncodings: CompressionAlgorithmSet = [],
    maxPayloadSize: Int = .max,
    descriptorPromise: EventLoopPromise<MethodDescriptor>? = nil,
    disableAssertions: Bool = false
  ) -> ConnectionAndStreamHandlers {
    let connectionManagementHandler = ServerConnectionManagementHandler(
      eventLoop: channel.eventLoop,
      maxIdleTime: nil,
      maxAge: nil,
      maxGraceTime: nil,
      keepaliveTime: nil,
      keepaliveTimeout: nil,
      allowKeepaliveWithoutCalls: false,
      minPingIntervalWithoutCalls: .minutes(5),
      requireALPN: false
    )
    let streamHandler = GRPCServerStreamHandler(
      scheme: scheme,
      acceptedEncodings: acceptedEncodings,
      maxPayloadSize: maxPayloadSize,
      methodDescriptorPromise: descriptorPromise ?? channel.eventLoop.makePromise(),
      eventLoop: channel.eventLoop,
      connectionManagementHandler: connectionManagementHandler.syncView,
      skipStateMachineAssertions: disableAssertions
    )

    return ConnectionAndStreamHandlers(
      streamHandler: streamHandler,
      connectionHandler: connectionManagementHandler
    )
  }

  @Test("ChannelShouldQuiesceEvent is buffered and turns into RPC cancellation")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func shouldQuiesceEventIsBufferedBeforeHandleIsSet() async throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerConnectionAndStreamHandlers(channel: channel).streamHandler
    try channel.pipeline.syncOperations.addHandler(handler)
    channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())

    await withServerContextRPCCancellationHandle { handle in
      handler.setCancellationHandle(handle)
      #expect(handle.isCancelled)
    }

    // Throwing is fine: the channel is closed abruptly, errors are expected.
    _ = try? channel.finish()
  }

  @Test("ChannelShouldQuiesceEvent turns into RPC cancellation")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func shouldQuiesceEventTriggersCancellation() async throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerConnectionAndStreamHandlers(channel: channel).streamHandler
    try channel.pipeline.syncOperations.addHandler(handler)

    await withServerContextRPCCancellationHandle { handle in
      handler.setCancellationHandle(handle)
      #expect(!handle.isCancelled)
      channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
      #expect(handle.isCancelled)
    }

    // Throwing is fine: the channel is closed abruptly, errors are expected.
    _ = try? channel.finish()
  }

  @Test("RST_STREAM turns into RPC cancellation")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func rstStreamTriggersCancellation() async throws {
    let channel = EmbeddedChannel()
    let handler = self.makeServerConnectionAndStreamHandlers(channel: channel).streamHandler
    try channel.pipeline.syncOperations.addHandler(handler)

    await withServerContextRPCCancellationHandle { handle in
      handler.setCancellationHandle(handle)
      #expect(!handle.isCancelled)

      let rstStream: HTTP2Frame.FramePayload = .rstStream(.cancel)
      channel.pipeline.fireChannelRead(rstStream)

      #expect(handle.isCancelled)
    }

    // Throwing is fine: the channel is closed abruptly, errors are expected.
    _ = try? channel.finish()
  }

  @Test("Connection FrameStats are updated when writing headers or data frames")
  @available(gRPCSwiftNIOTransport 2.0, *)
  func connectionFrameStatsAreUpdatedAccordingly() async throws {
    let channel = EmbeddedChannel()
    let handlers = self.makeServerConnectionAndStreamHandlers(channel: channel)
    try channel.pipeline.syncOperations.addHandler(handlers.streamHandler)

    // We have written nothing yet, so expect FrameStats/didWriteHeadersOrData to be false
    #expect(!handlers.connectionHandler.frameStats.didWriteHeadersOrData)

    // FrameStats aren't affected by pings received
    channel.pipeline.fireChannelRead(
      HTTP2Frame.FramePayload.ping(.init(withInteger: 42), ack: false)
    )
    #expect(!handlers.connectionHandler.frameStats.didWriteHeadersOrData)

    // Now write back headers and make sure FrameStats are updated accordingly:
    // To do that, we first need to receive client's initial metadata...
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/SomeService/SomeMethod",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    try channel.writeInbound(
      HTTP2Frame.FramePayload.headers(.init(headers: clientInitialMetadata))
    )

    // Now we write back server's initial metadata...
    let serverInitialMetadata = RPCResponsePart<GRPCNIOTransportBytes>.metadata([:])
    try channel.writeOutbound(serverInitialMetadata)

    // And this should have updated the FrameStats
    #expect(handlers.connectionHandler.frameStats.didWriteHeadersOrData)

    // Manually reset the FrameStats to make sure that writing data also updates it correctly.
    handlers.connectionHandler.frameStats.reset()
    #expect(!handlers.connectionHandler.frameStats.didWriteHeadersOrData)
    try channel.writeOutbound(RPCResponsePart.message(GRPCNIOTransportBytes([42])))
    #expect(handlers.connectionHandler.frameStats.didWriteHeadersOrData)

    // Clean up.
    // Throwing is fine: the channel is closed abruptly, errors are expected.
    _ = try? channel.finish()
  }
}

extension EmbeddedChannel {
  fileprivate func assertReadHeadersOutbound() throws -> HTTP2Frame.FramePayload.Headers {
    guard
      case .headers(let writtenHeaders) = try XCTUnwrap(
        try self.readOutbound(as: HTTP2Frame.FramePayload.self)
      )
    else {
      throw TestError.assertionFailure("Expected to write headers")
    }
    return writtenHeaders
  }

  fileprivate func assertReadDataOutbound() throws -> HTTP2Frame.FramePayload.Data {
    guard
      case .data(let writtenMessage) = try XCTUnwrap(
        try self.readOutbound(as: HTTP2Frame.FramePayload.self)
      )
    else {
      throw TestError.assertionFailure("Expected to write data")
    }
    return writtenMessage
  }
}

private enum TestError: Error {
  case assertionFailure(String)
}
