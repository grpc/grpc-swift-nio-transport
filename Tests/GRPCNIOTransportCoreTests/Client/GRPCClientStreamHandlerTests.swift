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
import NIOHTTP1
import NIOHTTP2
import XCTest

@testable import GRPCNIOTransportCore

@available(gRPCSwiftNIOTransport 2.0, *)
final class GRPCClientStreamHandlerTests: XCTestCase {
  func testH2FramesAreIgnored() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1
    )

    let channel = EmbeddedChannel(handler: handler)

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

  func testServerInitialMetadataMissingHTTPStatusCodeResultsInFinishedRPC() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Receive server's initial metadata without :status
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue
    ]

    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(code: .unknown, message: "HTTP Status Code is missing."),
        Metadata(headers: serverInitialMetadata)
      )
    )
  }

  func testServerInitialMetadata1xxHTTPStatusCodeResultsInNothingRead() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Receive server's initial metadata with 1xx status
    let invalidServerInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "104",
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue,
    ]

    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: invalidServerInitialMetadata))
      )
    )

    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    // We are still expecting the correct headers after getting a 1xx response, so make sure we
    // don't fail if we get the metadata twice.
    let validServerInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      "some-custom-header": "some-custom-value",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: validServerInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.metadata(Metadata(headers: validServerInitialMetadata))
    )
  }

  func testServerInitialMetadataOtherNon200HTTPStatusCodeResultsInFinishedRPC() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Receive server's initial metadata with non-200 and non-1xx :status
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: String(HTTPResponseStatus.tooManyRequests.code),
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue,
    ]

    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(code: .unavailable, message: "Unexpected non-200 HTTP Status Code."),
        Metadata(headers: serverInitialMetadata)
      )
    )

    // We should not throw if the server sends another message:
    // we should drop it, since the server is now closed.
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let serverDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame.FramePayload.data(serverDataPayload)))
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))
  }

  func testServerInitialMetadataMissingContentTypeResultsInFinishedRPC() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Receive server's initial metadata without content-type
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200"
    ]

    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(code: .internalError, message: "Missing content-type header"),
        Metadata(headers: serverInitialMetadata)
      )
    )
  }

  func testNotAcceptedEncodingResultsInFinishedRPC() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .deflate,
      acceptedEncodings: [.deflate],
      maxPayloadSize: 1
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    XCTAssertNoThrow(
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    )

    // Make sure we have sent right metadata.
    let writtenMetadata = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenMetadata.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",
        GRPCHTTP2Keys.encoding.rawValue: "deflate",
        GRPCHTTP2Keys.acceptEncoding.rawValue: "deflate",
      ]
    )

    // Server sends initial metadata with unsupported encoding
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue,
      GRPCHTTP2Keys.encoding.rawValue: "gzip",
    ]

    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(
          code: .internalError,
          message:
            "The server picked a compression algorithm ('gzip') the client does not know about."
        ),
        Metadata(headers: serverInitialMetadata)
      )
    )
  }

  func testOverMaximumPayloadSize() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    XCTAssertNoThrow(
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    )

    // Make sure we have sent right metadata.
    let writtenMetadata = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenMetadata.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",
      ]
    )

    // Server sends initial metadata
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue,
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .metadata(Metadata(headers: serverInitialMetadata))
    )

    // Server sends message over payload limit
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let clientDataPayload = HTTP2Frame.FramePayload.Data(
      data: .byteBuffer(buffer),
      endStream: false
    )

    // Invalid payload should result in error status and stream being closed
    try channel.writeInbound(HTTP2Frame.FramePayload.data(clientDataPayload))
    let part = try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self)
    XCTAssertEqual(
      part,
      .status(Status(code: .internalError, message: "Failed to decode message"), [:])
    )
    channel.embeddedEventLoop.run()
    try channel.closeFuture.wait()
  }

  func testServerSendsEOSWhenSendingMessage_ResultsInErrorStatus() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 100,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    XCTAssertNoThrow(
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    )

    // Make sure we have sent right metadata.
    let writtenMetadata = try channel.assertReadHeadersOutbound()

    XCTAssertEqual(
      writtenMetadata.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",
      ]
    )

    // Server sends initial metadata
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: ContentType.grpc.canonicalValue,
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .metadata(Metadata(headers: serverInitialMetadata))
    )

    // Server sends message with EOS set.
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let clientDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame.FramePayload.data(clientDataPayload)))

    // Make sure we got status + trailers with the right error.
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        Status(
          code: .internalError,
          message:
            "Server sent EOS alongside a data frame, but server is only allowed to close by sending status and trailers."
        ),
        [:]
      )
    )
  }

  func testServerEndsStream() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Write client's initial metadata
    XCTAssertNoThrow(try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])))
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    let writtenInitialMetadata = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(writtenInitialMetadata.headers, clientInitialMetadata)

    // Receive server's initial metadata with end stream set
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.grpcStatus.rawValue: "0",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(
          .init(
            headers: serverInitialMetadata,
            endStream: true
          )
        )
      )
    )
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(code: .ok, message: ""),
        [
          GRPCHTTP2Keys.status.rawValue: "200",
          GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        ]
      )
    )

    // We should not throw if the server sends another message:
    // we should drop it, since the server is now closed.
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let serverDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
    XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame.FramePayload.data(serverDataPayload)))
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    // We should also not throw if the server sends trailers again.
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata, endStream: true))
      )
    )
  }

  func testNormalFlow() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 100,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Make sure we have sent the corresponding frame, and that nothing has been written back.
    let writtenHeaders = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",

      ]
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    // Receive server's initial metadata
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      "some-custom-header": "some-custom-value",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.metadata(Metadata(headers: serverInitialMetadata))
    )

    // Send a message
    XCTAssertNoThrow(
      try channel.writeOutbound(
        RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 1, count: 42))
      )
    )

    // Assert we wrote it successfully into the channel
    let writtenMessage = try channel.assertReadDataOutbound()
    var expectedBuffer = ByteBuffer()
    expectedBuffer.writeInteger(UInt8(0))  // not compressed
    expectedBuffer.writeInteger(UInt32(42))  // message length
    expectedBuffer.writeRepeatingByte(1, count: 42)  // message
    XCTAssertEqual(writtenMessage.data, .byteBuffer(expectedBuffer))

    // Half-close the outbound end: this would be triggered by finishing the client's writer.
    XCTAssertNoThrow(channel.close(mode: .output, promise: nil))

    // Make sure the EOS frame was sent
    let emptyEOSFrame = try channel.assertReadDataOutbound()
    XCTAssertEqual(emptyEOSFrame.data, .byteBuffer(.init()))
    XCTAssertTrue(emptyEOSFrame.endStream)

    // Make sure that, if we flush again, we're not writing anything else down
    // the stream. We should have closed at this point.
    channel.flush()
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Make sure we cannot write anymore because client's closed.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(
        RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 1, count: 42))
      )
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }

    // This is needed to clear the EmbeddedChannel's stored error, otherwise
    // it will be thrown when writing inbound.
    try? channel.throwIfErrorCaught()

    // Server sends back response message
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    buffer.writeInteger(UInt32(42))  // message length
    buffer.writeRepeatingByte(0, count: 42)  // message
    let serverDataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer))
    XCTAssertNoThrow(try channel.writeInbound(HTTP2Frame.FramePayload.data(serverDataPayload)))

    // Make sure we read the message properly
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.message(GRPCNIOTransportBytes(repeating: 0, count: 42))
    )

    // Server sends status to end RPC
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(
          .init(headers: [
            GRPCHTTP2Keys.grpcStatus.rawValue: String(Status.Code.dataLoss.rawValue),
            GRPCHTTP2Keys.grpcStatusMessage.rawValue: "Test data loss",
            "custom-header": "custom-value",
          ])
        )
      )
    )

    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(.init(code: .dataLoss, message: "Test data loss"), ["custom-header": "custom-value"])
    )
  }

  func testReceiveMessageSplitAcrossMultipleBuffers() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 100,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Make sure we have sent the corresponding frame, and that nothing has been written back.
    let writtenHeaders = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",

      ]
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    // Receive server's initial metadata
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      "some-custom-header": "some-custom-value",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.metadata(Metadata(headers: serverInitialMetadata))
    )

    // Send a message
    XCTAssertNoThrow(
      try channel.writeOutbound(
        RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 1, count: 42))
      )
    )

    // Assert we wrote it successfully into the channel
    let writtenMessage = try channel.assertReadDataOutbound()
    var expectedBuffer = ByteBuffer()
    expectedBuffer.writeInteger(UInt8(0))  // not compressed
    expectedBuffer.writeInteger(UInt32(42))  // message length
    expectedBuffer.writeRepeatingByte(1, count: 42)  // message
    XCTAssertEqual(writtenMessage.data, .byteBuffer(expectedBuffer))

    // Receive server's first message
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(0))  // not compressed
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeInteger(UInt32(30))  // message length
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(0, count: 10)  // first part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(1, count: 10)  // second part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    buffer.clear()
    buffer.writeRepeatingByte(2, count: 10)  // third part of the message
    XCTAssertNoThrow(
      try channel.writeInbound(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer))))
    )

    var expected = ByteBuffer()
    expected.writeRepeatingByte(0, count: 10)
    expected.writeRepeatingByte(1, count: 10)
    expected.writeRepeatingByte(2, count: 10)
    // Make sure we read the message properly
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.message(GRPCNIOTransportBytes(expected))
    )
  }

  func testSendMultipleMessagesInSingleBuffer() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 100,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Send client's initial metadata
    let request = RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])
    XCTAssertNoThrow(try channel.writeOutbound(request))

    // Make sure we have sent the corresponding frame, and that nothing has been written back.
    let writtenHeaders = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(
      writtenHeaders.headers,
      [
        GRPCHTTP2Keys.method.rawValue: "POST",
        GRPCHTTP2Keys.scheme.rawValue: "http",
        GRPCHTTP2Keys.path.rawValue: "/test/test",
        GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
        GRPCHTTP2Keys.te.rawValue: "trailers",

      ]
    )
    XCTAssertNil(try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self))

    // Receive server's initial metadata
    let serverInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.status.rawValue: "200",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      "some-custom-header": "some-custom-value",
    ]
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.headers(.init(headers: serverInitialMetadata))
      )
    )
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      RPCResponsePart.metadata(Metadata(headers: serverInitialMetadata))
    )

    // This is where this test actually begins. We want to write two messages
    // without flushing, and make sure that no messages are sent down the pipeline
    // until we flush. Once we flush, both messages should be sent in the same ByteBuffer.

    // Write back first message and make sure nothing's written in the channel.
    XCTAssertNoThrow(
      channel.write(RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 1, count: 4)))
    )
    XCTAssertNil(try channel.readOutbound(as: HTTP2Frame.FramePayload.self))

    // Write back second message and make sure nothing's written in the channel.
    XCTAssertNoThrow(
      channel.write(RPCRequestPart.message(GRPCNIOTransportBytes(repeating: 2, count: 4)))
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

  func testUnexpectedStreamClose_ErrorFired() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Write client's initial metadata
    XCTAssertNoThrow(try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])))
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    let writtenInitialMetadata = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(writtenInitialMetadata.headers, clientInitialMetadata)

    // An error is fired down the pipeline
    let thrownError = ChannelError.connectTimeout(.milliseconds(100))
    channel.pipeline.fireErrorCaught(thrownError)

    // The client receives a status explaining the stream was closed because of the thrown error.
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(
          code: .unavailable,
          message: "Stream unexpectedly closed with error."
        ),
        [:]
      )
    )

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testUnexpectedStreamClose_ChannelInactive() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Write client's initial metadata
    XCTAssertNoThrow(try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])))
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    let writtenInitialMetadata = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(writtenInitialMetadata.headers, clientInitialMetadata)

    // Channel becomes inactive
    channel.pipeline.fireChannelInactive()

    // The client receives a status explaining the stream was closed.
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(code: .unavailable, message: "Stream unexpectedly closed."),
        [:]
      )
    )

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
  }

  func testUnexpectedStreamClose_ResetStreamFrame() throws {
    let handler = GRPCClientStreamHandler(
      methodDescriptor: .testTest,
      scheme: .http,
      authority: nil,
      outboundEncoding: .none,
      acceptedEncodings: [],
      maxPayloadSize: 1,
      skipStateMachineAssertions: true
    )

    let channel = EmbeddedChannel(handler: handler)

    // Write client's initial metadata
    XCTAssertNoThrow(try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:])))
    let clientInitialMetadata: HPACKHeaders = [
      GRPCHTTP2Keys.path.rawValue: "/test/test",
      GRPCHTTP2Keys.scheme.rawValue: "http",
      GRPCHTTP2Keys.method.rawValue: "POST",
      GRPCHTTP2Keys.contentType.rawValue: "application/grpc",
      GRPCHTTP2Keys.te.rawValue: "trailers",
    ]
    let writtenInitialMetadata = try channel.assertReadHeadersOutbound()
    XCTAssertEqual(writtenInitialMetadata.headers, clientInitialMetadata)

    // Receive RST_STREAM
    XCTAssertNoThrow(
      try channel.writeInbound(
        HTTP2Frame.FramePayload.rstStream(.internalError)
      )
    )

    // The client receives a status explaining RST_STREAM was sent.
    XCTAssertEqual(
      try channel.readInbound(as: RPCResponsePart<GRPCNIOTransportBytes>.self),
      .status(
        .init(
          code: .unavailable,
          message: "Stream unexpectedly closed: a RST_STREAM frame was received."
        ),
        [:]
      )
    )

    // We should now be closed: check we can't write anymore.
    XCTAssertThrowsError(
      ofType: RPCError.self,
      try channel.writeOutbound(RPCRequestPart<GRPCNIOTransportBytes>.metadata([:]))
    ) { error in
      XCTAssertEqual(error.code, .internalError)
      XCTAssertEqual(error.message, "Invalid state")
    }
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

@available(gRPCSwiftNIOTransport 2.0, *)
extension MethodDescriptor {
  static let testTest = Self(fullyQualifiedService: "test", method: "test")
}
