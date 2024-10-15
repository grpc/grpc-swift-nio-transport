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

internal struct ControlClient {
  internal let client: GRPCCore.GRPCClient

  internal init(wrapping client: GRPCCore.GRPCClient) {
    self.client = client
  }

  internal func unary<R>(
    request: GRPCCore.ClientRequest<ControlInput>,
    options: GRPCCore.CallOptions = .defaults,
    _ body: @Sendable @escaping (GRPCCore.ClientResponse<ControlOutput>) async throws -> R =
      {
        try $0.message
      }
  ) async throws -> R where R: Sendable {
    try await self.client.unary(
      request: request,
      descriptor: MethodDescriptor(service: "Control", method: "Unary"),
      serializer: JSONSerializer(),
      deserializer: JSONDeserializer(),
      options: options,
      handler: body
    )
  }

  internal func serverStream<R>(
    request: GRPCCore.ClientRequest<ControlInput>,
    options: GRPCCore.CallOptions = .defaults,
    _ body: @Sendable @escaping (GRPCCore.StreamingClientResponse<ControlOutput>) async throws -> R
  ) async throws -> R where R: Sendable {
    try await self.client.serverStreaming(
      request: request,
      descriptor: MethodDescriptor(service: "Control", method: "ServerStream"),
      serializer: JSONSerializer(),
      deserializer: JSONDeserializer(),
      options: options,
      handler: body
    )
  }

  internal func clientStream<R>(
    request: GRPCCore.StreamingClientRequest<ControlInput>,
    options: GRPCCore.CallOptions = .defaults,
    _ body: @Sendable @escaping (GRPCCore.ClientResponse<ControlOutput>) async throws -> R =
      {
        try $0.message
      }
  ) async throws -> R where R: Sendable {
    try await self.client.clientStreaming(
      request: request,
      descriptor: MethodDescriptor(service: "Control", method: "ClientStream"),
      serializer: JSONSerializer(),
      deserializer: JSONDeserializer(),
      options: options,
      handler: body
    )
  }

  internal func bidiStream<R>(
    request: GRPCCore.StreamingClientRequest<ControlInput>,
    options: GRPCCore.CallOptions = .defaults,
    _ body: @Sendable @escaping (GRPCCore.StreamingClientResponse<ControlOutput>) async throws -> R
  ) async throws -> R where R: Sendable {
    try await self.client.bidirectionalStreaming(
      request: request,
      descriptor: MethodDescriptor(service: "Control", method: "BidiStream"),
      serializer: JSONSerializer(),
      deserializer: JSONDeserializer(),
      options: options,
      handler: body
    )
  }

  internal func waitForCancellation<R>(
    request: GRPCCore.ClientRequest<CancellationKind>,
    options: GRPCCore.CallOptions = .defaults,
    _ body: @Sendable @escaping (
      _ response: GRPCCore.StreamingClientResponse<CancellationKind>
    ) async throws -> R
  ) async throws -> R where R: Sendable {
    try await self.client.serverStreaming(
      request: request,
      descriptor: MethodDescriptor(service: "Control", method: "WaitForCancellation"),
      serializer: JSONSerializer(),
      deserializer: JSONDeserializer(),
      options: options,
      handler: body
    )
  }
}
