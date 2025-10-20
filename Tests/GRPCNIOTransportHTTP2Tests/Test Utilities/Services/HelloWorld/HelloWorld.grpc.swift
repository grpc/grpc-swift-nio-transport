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

import GRPCCore

import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

// MARK: - HelloWorld

/// Namespace containing generated types for the "HelloWorld" service.
@available(gRPCSwiftNIOTransport 2.2, *)
internal enum HelloWorld {
  /// Service descriptor for the "HelloWorld" service.
  internal static let descriptor = GRPCCore.ServiceDescriptor(fullyQualifiedService: "HelloWorld")
  /// Namespace for method metadata.
  internal enum Method {
    /// Namespace for "sayHello" metadata.
    internal enum sayHello {
      /// Request type for "sayHello".
      internal typealias Input = HelloRequest
      /// Response type for "sayHello".
      internal typealias Output = HelloResponse
      /// Descriptor for "sayHello".
      internal static let descriptor = GRPCCore.MethodDescriptor(
        service: GRPCCore.ServiceDescriptor(fullyQualifiedService: "HelloWorld"),
        method: "sayHello"
      )
    }
    /// Descriptors for all methods in the "HelloWorld" service.
    internal static let descriptors: [GRPCCore.MethodDescriptor] = [
      sayHello.descriptor
    ]
  }
}

@available(gRPCSwiftNIOTransport 2.2, *)
extension GRPCCore.ServiceDescriptor {
  /// Service descriptor for the "HelloWorld" service.
  internal static let HelloWorld = GRPCCore.ServiceDescriptor(fullyQualifiedService: "HelloWorld")
}

// MARK: HelloWorld (server)

@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld {
  /// Streaming variant of the service protocol for the "HelloWorld" service.
  ///
  /// This protocol is the lowest-level of the service protocols generated for this service
  /// giving you the most flexibility over the implementation of your service. This comes at
  /// the cost of more verbose and less strict APIs. Each RPC requires you to implement it in
  /// terms of a request stream and response stream. Where only a single request or response
  /// message is expected, you are responsible for enforcing this invariant is maintained.
  ///
  /// Where possible, prefer using the stricter, less-verbose ``ServiceProtocol``
  /// or ``SimpleServiceProtocol`` instead.
  internal protocol StreamingServiceProtocol: GRPCCore.RegistrableRPCService {
    /// Handle the "sayHello" method.
    ///
    /// - Parameters:
    ///   - request: A streaming request of `HelloRequest` messages.
    ///   - context: Context providing information about the RPC.
    /// - Throws: Any error which occurred during the processing of the request. Thrown errors
    ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
    ///     to an internal error.
    /// - Returns: A streaming response of `HelloResponse` messages.
    func sayHello(
      request: GRPCCore.StreamingServerRequest<HelloRequest>,
      context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<HelloResponse>
  }

  /// Service protocol for the "HelloWorld" service.
  ///
  /// This protocol is higher level than ``StreamingServiceProtocol`` but lower level than
  /// the ``SimpleServiceProtocol``, it provides access to request and response metadata and
  /// trailing response metadata. If you don't need these then consider using
  /// the ``SimpleServiceProtocol``. If you need fine grained control over your RPCs then
  /// use ``StreamingServiceProtocol``.
  internal protocol ServiceProtocol: HelloWorld.StreamingServiceProtocol {
    /// Handle the "sayHello" method.
    ///
    /// - Parameters:
    ///   - request: A request containing a single `HelloRequest` message.
    ///   - context: Context providing information about the RPC.
    /// - Throws: Any error which occurred during the processing of the request. Thrown errors
    ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
    ///     to an internal error.
    /// - Returns: A response containing a single `HelloResponse` message.
    func sayHello(
      request: GRPCCore.ServerRequest<HelloRequest>,
      context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<HelloResponse>
  }

  /// Simple service protocol for the "HelloWorld" service.
  ///
  /// This is the highest level protocol for the service. The API is the easiest to use but
  /// doesn't provide access to request or response metadata. If you need access to these
  /// then use ``ServiceProtocol`` instead.
  internal protocol SimpleServiceProtocol: HelloWorld.ServiceProtocol {
    /// Handle the "sayHello" method.
    ///
    /// - Parameters:
    ///   - request: A `HelloRequest` message.
    ///   - context: Context providing information about the RPC.
    /// - Throws: Any error which occurred during the processing of the request. Thrown errors
    ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
    ///     to an internal error.
    /// - Returns: A `HelloResponse` to respond with.
    func sayHello(
      request: HelloRequest,
      context: GRPCCore.ServerContext
    ) async throws -> HelloResponse
  }
}

// Default implementation of 'registerMethods(with:)'.
@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld.StreamingServiceProtocol {
  internal func registerMethods<Transport>(
    with router: inout GRPCCore.RPCRouter<Transport>
  ) where Transport: GRPCCore.ServerTransport {
    router.registerHandler(
      forMethod: HelloWorld.Method.sayHello.descriptor,
      deserializer: JSONDeserializer<HelloRequest>(),
      serializer: JSONSerializer<HelloResponse>(),
      handler: { request, context in
        try await self.sayHello(
          request: request,
          context: context
        )
      }
    )
  }
}

// Default implementation of streaming methods from 'StreamingServiceProtocol'.
@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld.ServiceProtocol {
  internal func sayHello(
    request: GRPCCore.StreamingServerRequest<HelloRequest>,
    context: GRPCCore.ServerContext
  ) async throws -> GRPCCore.StreamingServerResponse<HelloResponse> {
    let response = try await self.sayHello(
      request: GRPCCore.ServerRequest(stream: request),
      context: context
    )
    return GRPCCore.StreamingServerResponse(single: response)
  }
}

// Default implementation of methods from 'ServiceProtocol'.
@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld.SimpleServiceProtocol {
  internal func sayHello(
    request: GRPCCore.ServerRequest<HelloRequest>,
    context: GRPCCore.ServerContext
  ) async throws -> GRPCCore.ServerResponse<HelloResponse> {
    return GRPCCore.ServerResponse<HelloResponse>(
      message: try await self.sayHello(
        request: request.message,
        context: context
      ),
      metadata: [:]
    )
  }
}

// MARK: HelloWorld (client)

@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld {
  /// Generated client protocol for the "HelloWorld" service.
  ///
  /// You don't need to implement this protocol directly, use the generated
  /// implementation, ``Client``.
  internal protocol ClientProtocol: Sendable {
    /// Call the "sayHello" method.
    ///
    /// - Parameters:
    ///   - request: A request containing a single `HelloRequest` message.
    ///   - serializer: A serializer for `HelloRequest` messages.
    ///   - deserializer: A deserializer for `HelloResponse` messages.
    ///   - options: Options to apply to this RPC.
    ///   - handleResponse: A closure which handles the response, the result of which is
    ///       returned to the caller. Returning from the closure will cancel the RPC if it
    ///       hasn't already finished.
    /// - Returns: The result of `handleResponse`.
    func sayHello<Result>(
      request: GRPCCore.ClientRequest<HelloRequest>,
      serializer: some GRPCCore.MessageSerializer<HelloRequest>,
      deserializer: some GRPCCore.MessageDeserializer<HelloResponse>,
      options: GRPCCore.CallOptions,
      onResponse handleResponse:
        @Sendable @escaping (GRPCCore.ClientResponse<HelloResponse>) async throws -> Result
    ) async throws -> Result where Result: Sendable
  }

  /// Generated client for the "HelloWorld" service.
  ///
  /// The ``Client`` provides an implementation of ``ClientProtocol`` which wraps
  /// a `GRPCCore.GRPCCClient`. The underlying `GRPCClient` provides the long-lived
  /// means of communication with the remote peer.
  internal struct Client<Transport>: ClientProtocol where Transport: GRPCCore.ClientTransport {
    private let client: GRPCCore.GRPCClient<Transport>

    /// Creates a new client wrapping the provided `GRPCCore.GRPCClient`.
    ///
    /// - Parameters:
    ///   - client: A `GRPCCore.GRPCClient` providing a communication channel to the service.
    internal init(wrapping client: GRPCCore.GRPCClient<Transport>) {
      self.client = client
    }

    /// Call the "sayHello" method.
    ///
    /// - Parameters:
    ///   - request: A request containing a single `HelloRequest` message.
    ///   - serializer: A serializer for `HelloRequest` messages.
    ///   - deserializer: A deserializer for `HelloResponse` messages.
    ///   - options: Options to apply to this RPC.
    ///   - handleResponse: A closure which handles the response, the result of which is
    ///       returned to the caller. Returning from the closure will cancel the RPC if it
    ///       hasn't already finished.
    /// - Returns: The result of `handleResponse`.
    internal func sayHello<Result>(
      request: GRPCCore.ClientRequest<HelloRequest>,
      serializer: some GRPCCore.MessageSerializer<HelloRequest>,
      deserializer: some GRPCCore.MessageDeserializer<HelloResponse>,
      options: GRPCCore.CallOptions = .defaults,
      onResponse handleResponse:
        @Sendable @escaping (GRPCCore.ClientResponse<HelloResponse>) async throws -> Result = {
          response in
          try response.message
        }
    ) async throws -> Result where Result: Sendable {
      try await self.client.unary(
        request: request,
        descriptor: HelloWorld.Method.sayHello.descriptor,
        serializer: serializer,
        deserializer: deserializer,
        options: options,
        onResponse: handleResponse
      )
    }
  }
}

// Helpers providing default arguments to 'ClientProtocol' methods.
@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld.ClientProtocol {
  /// Call the "sayHello" method.
  ///
  /// - Parameters:
  ///   - request: A request containing a single `HelloRequest` message.
  ///   - options: Options to apply to this RPC.
  ///   - handleResponse: A closure which handles the response, the result of which is
  ///       returned to the caller. Returning from the closure will cancel the RPC if it
  ///       hasn't already finished.
  /// - Returns: The result of `handleResponse`.
  internal func sayHello<Result>(
    request: GRPCCore.ClientRequest<HelloRequest>,
    options: GRPCCore.CallOptions = .defaults,
    onResponse handleResponse:
      @Sendable @escaping (GRPCCore.ClientResponse<HelloResponse>) async throws -> Result = {
        response in
        try response.message
      }
  ) async throws -> Result where Result: Sendable {
    try await self.sayHello(
      request: request,
      serializer: JSONSerializer<HelloRequest>(),
      deserializer: JSONDeserializer<HelloResponse>(),
      options: options,
      onResponse: handleResponse
    )
  }
}

// Helpers providing sugared APIs for 'ClientProtocol' methods.
@available(gRPCSwiftNIOTransport 2.2, *)
extension HelloWorld.ClientProtocol {
  /// Call the "sayHello" method.
  ///
  /// - Parameters:
  ///   - message: request message to send.
  ///   - metadata: Additional metadata to send, defaults to empty.
  ///   - options: Options to apply to this RPC, defaults to `.defaults`.
  ///   - handleResponse: A closure which handles the response, the result of which is
  ///       returned to the caller. Returning from the closure will cancel the RPC if it
  ///       hasn't already finished.
  /// - Returns: The result of `handleResponse`.
  internal func sayHello<Result>(
    _ message: HelloRequest,
    metadata: GRPCCore.Metadata = [:],
    options: GRPCCore.CallOptions = .defaults,
    onResponse handleResponse:
      @Sendable @escaping (GRPCCore.ClientResponse<HelloResponse>) async throws -> Result = {
        response in
        try response.message
      }
  ) async throws -> Result where Result: Sendable {
    let request = GRPCCore.ClientRequest<HelloRequest>(
      message: message,
      metadata: metadata
    )
    return try await self.sayHello(
      request: request,
      options: options,
      onResponse: handleResponse
    )
  }
}
