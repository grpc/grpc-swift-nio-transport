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

package import GRPCCore
package import NIOCore

@available(gRPCSwiftNIOTransport 2.0, *)
package enum ServerConnection {
  package enum Stream {
    package struct Outbound: ClosableRPCWriterProtocol {
      package typealias Element = RPCResponsePart<GRPCNIOTransportBytes>

      private let responseWriter:
        NIOAsyncChannelOutboundWriter<
          RPCResponsePart<GRPCNIOTransportBytes>
        >
      private let http2Stream:
        NIOAsyncChannel<
          RPCRequestPart<GRPCNIOTransportBytes>,
          RPCResponsePart<GRPCNIOTransportBytes>
        >

      package init(
        responseWriter: NIOAsyncChannelOutboundWriter<RPCResponsePart<GRPCNIOTransportBytes>>,
        http2Stream: NIOAsyncChannel<
          RPCRequestPart<GRPCNIOTransportBytes>,
          RPCResponsePart<GRPCNIOTransportBytes>
        >
      ) {
        self.responseWriter = responseWriter
        self.http2Stream = http2Stream
      }

      package func write(_ element: RPCResponsePart<GRPCNIOTransportBytes>) async throws {
        try await self.responseWriter.write(element)
      }

      package func write(contentsOf elements: some Sequence<Self.Element>) async throws {
        try await self.responseWriter.write(contentsOf: elements)
      }

      package func finish() {
        self.responseWriter.finish()
      }

      package func finish(throwing error: any Error) {
        // Fire the error inbound; this fails the inbound writer.
        self.http2Stream.channel.pipeline.fireErrorCaught(error)
      }
    }
  }
}
