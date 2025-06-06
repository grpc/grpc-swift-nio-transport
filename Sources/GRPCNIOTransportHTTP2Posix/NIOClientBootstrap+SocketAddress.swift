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

internal import GRPCCore
internal import GRPCNIOTransportCore
internal import NIOCore
internal import NIOPosix

@available(gRPCSwiftNIOTransport 2.0, *)
extension ClientBootstrap {
  func connect<Result: Sendable>(
    to address: GRPCNIOTransportCore.SocketAddress,
    _ configure: @Sendable @escaping (any Channel) -> EventLoopFuture<Result>
  ) async throws -> Result {
    if let ipv4 = address.ipv4 {
      return try await self.connect(to: NIOCore.SocketAddress(ipv4), channelInitializer: configure)
    } else if let ipv6 = address.ipv6 {
      return try await self.connect(to: NIOCore.SocketAddress(ipv6), channelInitializer: configure)
    } else if let uds = address.unixDomainSocket {
      return try await self.connect(to: NIOCore.SocketAddress(uds), channelInitializer: configure)
    } else if let vsock = address.virtualSocket {
      return try await self.connect(to: VsockAddress(vsock), channelInitializer: configure)
    } else {
      throw RuntimeError(
        code: .transportError,
        message: """
          Unhandled socket address '\(address)', this is a gRPC Swift bug. Please file an issue \
          against the project.
          """
      )
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension NIOPosix.VsockAddress {
  init(_ address: GRPCNIOTransportCore.SocketAddress.VirtualSocket) {
    self.init(
      cid: ContextID(rawValue: address.contextID.rawValue),
      port: Port(rawValue: address.port.rawValue)
    )
  }
}
