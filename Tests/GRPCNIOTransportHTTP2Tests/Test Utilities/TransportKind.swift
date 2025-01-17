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
import GRPCNIOTransportHTTP2

enum TransportKind: CaseIterable, Hashable, Sendable {
  case posix
  #if canImport(Network)
  case transportServices
  #endif

  static var supported: [Self] {
    Self.allCases
  }
}

enum NIOClientTransport: ClientTransport {
  case posix(HTTP2ClientTransport.Posix)
  #if canImport(Network)
  case transportServices(HTTP2ClientTransport.TransportServices)
  #endif

  init(_ transport: HTTP2ClientTransport.Posix) {
    self = .posix(transport)
  }

  #if canImport(Network)
  init(_ transport: HTTP2ClientTransport.TransportServices) {
    self = .transportServices(transport)
  }
  #endif

  typealias Bytes = GRPCNIOTransportBytes

  var retryThrottle: GRPCCore.RetryThrottle? {
    switch self {
    case .posix(let transport):
      return transport.retryThrottle
    #if canImport(Network)
    case .transportServices(let transport):
      return transport.retryThrottle
    #endif
    }
  }

  func connect() async throws {
    switch self {
    case .posix(let transport):
      try await transport.connect()
    #if canImport(Network)
    case .transportServices(let transport):
      try await transport.connect()
    #endif
    }
  }

  func beginGracefulShutdown() {
    switch self {
    case .posix(let transport):
      transport.beginGracefulShutdown()
    #if canImport(Network)
    case .transportServices(let transport):
      transport.beginGracefulShutdown()
    #endif
    }
  }

  func withStream<T: Sendable>(
    descriptor: MethodDescriptor,
    options: CallOptions,
    _ closure: (_ stream: RPCStream<Inbound, Outbound>, _ context: ClientContext) async throws -> T
  ) async throws -> T {
    switch self {
    case .posix(let transport):
      return try await transport.withStream(descriptor: descriptor, options: options, closure)
    #if canImport(Network)
    case .transportServices(let transport):
      return try await transport.withStream(descriptor: descriptor, options: options, closure)
    #endif
    }
  }

  func config(forMethod descriptor: GRPCCore.MethodDescriptor) -> GRPCCore.MethodConfig? {
    switch self {
    case .posix(let transport):
      return transport.config(forMethod: descriptor)
    #if canImport(Network)
    case .transportServices(let transport):
      return transport.config(forMethod: descriptor)
    #endif
    }
  }

}

enum NIOServerTransport: ServerTransport, ListeningServerTransport {
  case posix(HTTP2ServerTransport.Posix)
  #if canImport(Network)
  case transportServices(HTTP2ServerTransport.TransportServices)
  #endif

  init(_ transport: HTTP2ServerTransport.Posix) {
    self = .posix(transport)
  }

  #if canImport(Network)
  init(_ transport: HTTP2ServerTransport.TransportServices) {
    self = .transportServices(transport)
  }
  #endif

  typealias Bytes = GRPCNIOTransportBytes

  var listeningAddress: GRPCNIOTransportCore.SocketAddress {
    get async throws {
      switch self {
      case .posix(let transport):
        try await transport.listeningAddress
      #if canImport(Network)
      case .transportServices(let transport):
        try await transport.listeningAddress
      #endif
      }
    }
  }

  func listen(
    streamHandler: @escaping @Sendable (
      _ stream: RPCStream<Inbound, Outbound>,
      _ context: ServerContext
    ) async -> Void
  ) async throws {
    switch self {
    case .posix(let transport):
      try await transport.listen(streamHandler: streamHandler)
    #if canImport(Network)
    case .transportServices(let transport):
      try await transport.listen(streamHandler: streamHandler)
    #endif
    }
  }

  func beginGracefulShutdown() {
    switch self {
    case .posix(let transport):
      transport.beginGracefulShutdown()
    #if canImport(Network)
    case .transportServices(let transport):
      transport.beginGracefulShutdown()
    #endif
    }
  }
}
