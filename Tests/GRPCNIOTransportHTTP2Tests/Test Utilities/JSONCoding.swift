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

#if canImport(FoundationEssentials)
import struct FoundationEssentials.Data
import class FoundationEssentials.JSONEncoder
import class FoundationEssentials.JSONDecoder
#else
import struct Foundation.Data
import class Foundation.JSONEncoder
import class Foundation.JSONDecoder
#endif

@available(gRPCSwiftNIOTransport 1.0, *)
struct JSONCoder<Message: Codable>: MessageSerializer, MessageDeserializer {
  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    let json = JSONEncoder()
    let data = try json.encode(message)
    return Bytes(data)
  }

  func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> Message {
    let json = JSONDecoder()
    let data = serializedMessageBytes.withUnsafeBytes {
      Data($0)
    }
    return try json.decode(Message.self, from: data)
  }
}
