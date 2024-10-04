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

import Foundation
import GRPCCore

struct ControlService: RegistrableRPCService {
  func registerMethods(with router: inout RPCRouter) {
    router.registerHandler(
      forMethod: MethodDescriptor(service: "Control", method: "Unary"),
      deserializer: JSONDeserializer<ControlInput>(),
      serializer: JSONSerializer<ControlOutput>(),
      handler: { request, context in
        return try await self.handle(request: request)
      }
    )
    router.registerHandler(
      forMethod: MethodDescriptor(service: "Control", method: "ServerStream"),
      deserializer: JSONDeserializer<ControlInput>(),
      serializer: JSONSerializer<ControlOutput>(),
      handler: { request, context in
        return try await self.handle(request: request)
      }
    )
    router.registerHandler(
      forMethod: MethodDescriptor(service: "Control", method: "ClientStream"),
      deserializer: JSONDeserializer<ControlInput>(),
      serializer: JSONSerializer<ControlOutput>(),
      handler: { request, context in
        return try await self.handle(request: request)
      }
    )
    router.registerHandler(
      forMethod: MethodDescriptor(service: "Control", method: "BidiStream"),
      deserializer: JSONDeserializer<ControlInput>(),
      serializer: JSONSerializer<ControlOutput>(),
      handler: { request, context in
        return try await self.handle(request: request)
      }
    )
  }
}

extension ControlService {
  private func handle(
    request: StreamingServerRequest<ControlInput>
  ) async throws -> StreamingServerResponse<ControlOutput> {
    var iterator = request.messages.makeAsyncIterator()

    guard let message = try await iterator.next() else {
      // Empty input stream, empty output stream.
      return StreamingServerResponse { _ in [:] }
    }

    // Check if the request is for a trailers-only response.
    if let status = message.status, message.isTrailersOnly {
      let trailers = message.echoMetadataInTrailers ? request.metadata.echo() : [:]
      let code = Status.Code(rawValue: status.code.rawValue).flatMap { RPCError.Code($0) }

      if let code = code {
        throw RPCError(code: code, message: status.message, metadata: trailers)
      } else {
        // Invalid code, the request is invalid, so throw an appropriate error.
        throw RPCError(
          code: .invalidArgument,
          message: "Trailers only response must use a non-OK status code"
        )
      }
    }

    // Not a trailers-only response. Should the metadata be echo'd back?
    let metadata = message.echoMetadataInHeaders ? request.metadata.echo() : [:]

    // The iterator needs to be transferred into the response. This is okay: we won't touch the
    // iterator again from the current concurrency domain.
    let transfer = UnsafeTransfer(iterator)

    return StreamingServerResponse(metadata: metadata) { writer in
      // Finish dealing with the first message.
      switch try await self.processMessage(message, metadata: request.metadata, writer: writer) {
      case .return(let metadata):
        return metadata
      case .continue:
        ()
      }

      var iterator = transfer.wrappedValue
      // Process the rest of the messages.
      while let message = try await iterator.next() {
        switch try await self.processMessage(message, metadata: request.metadata, writer: writer) {
        case .return(let metadata):
          return metadata
        case .continue:
          ()
        }
      }

      // Input stream finished without explicitly setting a status; finish the RPC cleanly.
      return [:]
    }
  }

  private enum NextProcessingStep {
    case `return`(Metadata)
    case `continue`
  }

  private func processMessage(
    _ input: ControlInput,
    metadata: Metadata,
    writer: RPCWriter<ControlOutput>
  ) async throws -> NextProcessingStep {
    // If messages were requested, build a response and send them back.
    if input.numberOfMessages > 0 {
      let output = ControlOutput(
        payload: Data(
          repeating: input.payloadParameters.content,
          count: input.payloadParameters.size
        )
      )

      for _ in 0 ..< input.numberOfMessages {
        try await writer.write(output)
      }
    }

    // Check whether the RPC should be finished (i.e. the input `hasStatus`).
    guard let status = input.status else {
      if input.echoMetadataInTrailers {
        // There was no status in the input, but echo metadata in trailers was set. This is an
        // implicit 'ok' status.
        let trailers = input.echoMetadataInTrailers ? metadata.echo() : [:]
        return .return(trailers)
      } else {
        // No status, and not echoing back metadata. Continue consuming the input stream.
        return .continue
      }
    }

    // Build the trailers.
    let trailers = input.echoMetadataInTrailers ? metadata.echo() : [:]

    if status.code == .ok {
      return .return(trailers)
    }

    // Non-OK status code, throw an error.
    let code = RPCError.Code(status.code)

    if let code = code {
      // Valid error code, throw it.
      throw RPCError(code: code, message: status.message, metadata: trailers)
    } else {
      // Invalid error code, throw an appropriate error.
      throw RPCError(
        code: .invalidArgument,
        message: "Invalid error code '\(status.code)'"
      )
    }
  }
}

extension Metadata {
  fileprivate func echo() -> Self {
    var copy = Metadata()
    copy.reserveCapacity(self.count)

    for (key, value) in self {
      // Header field names mustn't contain ":".
      let key = "echo-" + key.replacingOccurrences(of: ":", with: "")
      switch value {
      case .string(let stringValue):
        copy.addString(stringValue, forKey: key)
      case .binary(let binaryValue):
        copy.addBinary(binaryValue, forKey: key)
      }
    }

    return copy
  }
}

private struct UnsafeTransfer<Wrapped> {
  var wrappedValue: Wrapped

  init(_ wrappedValue: Wrapped) {
    self.wrappedValue = wrappedValue
  }
}

extension UnsafeTransfer: @unchecked Sendable {}
