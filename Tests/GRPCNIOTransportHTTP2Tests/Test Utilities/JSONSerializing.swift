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

import Foundation
import GRPCCore

struct JSONSerializer<Message: Encodable>: MessageSerializer {
  private let encoder = JSONEncoder()

  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    let data = try self.encoder.encode(message)
    return Bytes(data)
  }
}

struct JSONDeserializer<Message: Decodable>: MessageDeserializer {
  private let decoder = JSONDecoder()

  func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> Message {
    try serializedMessageBytes.withUnsafeBytes {
      try self.decoder.decode(Message.self, from: Data($0))
    }
  }
}
