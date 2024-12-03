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

package enum PercentEncoding {
  package static func encodeAuthority(_ input: String) -> String {
    Self.encode(input) {
      Self.isAuthorityChar($0)
    }
  }

  package static func encode(
    _ input: String,
    isValidCharacter: (UInt8) -> Bool
  ) -> String {
    var output: [UInt8] = []
    output.reserveCapacity(input.utf8.count)

    for char in input.utf8 {
      if isValidCharacter(char) {
        output.append(char)
      } else {
        output.append(UInt8(ascii: "%"))
        output.append(Self.hexByte(char >> 4))
        output.append(Self.hexByte(char & 0xF))
      }
    }

    return String(decoding: output, as: UTF8.self)
  }

  private static func hexByte(_ nibble: UInt8) -> UInt8 {
    assert(nibble & 0xF == nibble)

    switch nibble {
    case 0 ... 9:
      return nibble &+ UInt8(ascii: "0")
    default:
      return nibble &+ (UInt8(ascii: "A") &- 10)
    }
  }

  // Characters from RFC 3986 § 2.2
  private static func isAlphaNumericChar(_ char: UInt8) -> Bool {
    switch char {
    case UInt8(ascii: "a") ... UInt8(ascii: "z"):
      return true
    case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
      return true
    case UInt8(ascii: "0") ... UInt8(ascii: "9"):
      return true
    default:
      return false
    }
  }

  // Characters from RFC 3986 § 2.2
  private static func isSubDelimChar(_ char: UInt8) -> Bool {
    switch char {
    case UInt8(ascii: "!"):
      return true
    case UInt8(ascii: "$"):
      return true
    case UInt8(ascii: "&"):
      return true
    case UInt8(ascii: "'"):
      return true
    case UInt8(ascii: "("):
      return true
    case UInt8(ascii: ")"):
      return true
    case UInt8(ascii: "*"):
      return true
    case UInt8(ascii: "+"):
      return true
    case UInt8(ascii: ","):
      return true
    case UInt8(ascii: ";"):
      return true
    case UInt8(ascii: "="):
      return true
    default:
      return false
    }
  }

  // Characters from RFC 3986 § 2.3
  private static func isUnreservedChar(_ char: UInt8) -> Bool {
    if Self.isAlphaNumericChar(char) { return true }

    switch char {
    case UInt8(ascii: "-"):
      return true
    case UInt8(ascii: "."):
      return true
    case UInt8(ascii: "_"):
      return true
    case UInt8(ascii: "~"):
      return true
    default:
      return false
    }
  }

  // Characters from RFC 3986 § 3.2
  private static func isAuthorityChar(_ char: UInt8) -> Bool {
    if Self.isUnreservedChar(char) { return true }
    if Self.isSubDelimChar(char) { return true }

    switch char {
    case UInt8(ascii: ":"):
      return true
    case UInt8(ascii: "["):
      return true
    case UInt8(ascii: "]"):
      return true
    case UInt8(ascii: "@"):
      return true
    default:
      return false
    }
  }
}
