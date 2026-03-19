/*
 * Copyright 2026, gRPC Authors All rights reserved.
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
import Testing

@testable import GRPCNIOTransportCore

struct MethodDescriptorIsKnownTests {
  @Test(arguments: [.unary, .serverStreaming] as [MethodDescriptor.RPCType?])
  @available(gRPCSwiftNIOTransport 2.4, *)
  func isKnownUnaryRequest(type: MethodDescriptor.RPCType?) {
    #expect(type.isKnownUnaryRequest)
  }

  @Test(arguments: [.clientStreaming, .bidirectionalStreaming, nil] as [MethodDescriptor.RPCType?])
  @available(gRPCSwiftNIOTransport 2.4, *)
  func isNotKnownUnaryRequest(type: MethodDescriptor.RPCType?) {
    #expect(!type.isKnownUnaryRequest)
  }

  @Test(arguments: [.unary, .clientStreaming] as [MethodDescriptor.RPCType?])
  @available(gRPCSwiftNIOTransport 2.4, *)
  func isKnownUnaryResponse(type: MethodDescriptor.RPCType?) {
    #expect(type.isKnownUnaryResponse)
  }

  @Test(arguments: [.serverStreaming, .bidirectionalStreaming, nil] as [MethodDescriptor.RPCType?])
  @available(gRPCSwiftNIOTransport 2.4, *)
  func isNotKnownUnaryResponse(type: MethodDescriptor.RPCType?) {
    #expect(!type.isKnownUnaryResponse)
  }
}
