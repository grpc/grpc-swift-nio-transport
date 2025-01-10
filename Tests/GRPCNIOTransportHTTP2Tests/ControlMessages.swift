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

struct ControlInput: Codable {
  /// Whether metadata should be echo'd back in the initial metadata.
  ///
  /// Ignored if the initial metadata has already been sent back to the
  /// client.
  ///
  /// Each header field name in the request headers will be prefixed with
  /// "echo-". For example the header field name "foo" will be returned
  /// as "echo-foo. Note that semicolons aren't valid in HTTP header field
  /// names (apart from pseudo headers). As such all semicolons should be
  /// removed (":path" should become "echo-path").
  var echoMetadataInHeaders: Bool = false

  /// Parameters for response messages.
  var payloadParameters: PayloadParameters = PayloadParameters(size: 0, content: 0)

  /// The number of response messages.
  var numberOfMessages: Int = 0

  /// The status code and message to use at the end of the RPC.
  ///
  /// If this is set then the RPC will be ended after `numberOfMessages`
  /// messages have been sent back to the client.
  var status: Status? = nil

  /// Whether the response should be trailers only.
  ///
  /// Ignored unless it's set on the first message on the stream. When set
  /// the RPC will be completed with a trailers-only response using the
  /// status code and message from 'status'. The request metadata will be
  /// included if 'echo_metadata_in_trailers' is set.
  ///
  /// If this is set then `numberOfMessages', 'messageParams', and
  /// `echoMetadataInHeaders` are ignored.
  var isTrailersOnly: Bool = false

  /// Whether metadata should be echo'd back in the trailing metadata.
  ///
  /// Ignored unless 'status' is set.
  ///
  /// Each header field name in the request headers will be prefixed with
  /// "echo-". For example the header field name "foo" will be returned
  /// as "echo-foo. Note that semicolons aren't valid in HTTP header field
  /// names (apart from pseudo headers). As such all semicolons should be
  /// removed (":path" should become "echo-path").
  var echoMetadataInTrailers: Bool = false

  /// Key-value pairs to add to the initial metadata.
  var initialMetadataToAdd: [String: String] = [:]

  /// Key-value pairs to add to the trailing metadata.
  var trailingMetadataToAdd: [String: String] = [:]

  struct Status: Codable {
    var code: GRPCCore.Status.Code
    var message: String

    init() {
      self.code = .ok
      self.message = ""
    }

    static func with(_ populate: (inout Self) -> Void) -> Self {
      var defaults = Self()
      populate(&defaults)
      return defaults
    }

    enum CodingKeys: CodingKey {
      case code
      case message
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let rawValue = try container.decode(Int.self, forKey: .code)
      self.code = GRPCCore.Status.Code(rawValue: rawValue) ?? .unknown
      self.message = try container.decode(String.self, forKey: .message)
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(self.code.rawValue, forKey: .code)
      try container.encode(self.message, forKey: .message)
    }
  }

  struct PayloadParameters: Codable {
    var size: Int
    var content: UInt8

    static func with(_ populate: (inout Self) -> Void) -> Self {
      var defaults = Self(size: 0, content: 0)
      populate(&defaults)
      return defaults
    }
  }

  static func with(_ populate: (inout Self) -> Void) -> Self {
    var defaults = Self()
    populate(&defaults)
    return defaults
  }
}

struct ControlOutput: Codable {
  var payload: Data
}

enum CancellationKind: Codable {
  case awaitCancelled
  case withCancellationHandler
}

struct Empty: Codable {
}

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
