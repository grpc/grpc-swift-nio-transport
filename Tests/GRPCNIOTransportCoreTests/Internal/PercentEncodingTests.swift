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

import GRPCNIOTransportCore
import Testing

@Suite("Percent encoding")
struct PercentEncodingTests {
  @Test(
    "encode ':authority'",
    arguments: [
      ("", ""),
      ("foo", "foo"),
      ("FOO", "FOO"),
      ("f00", "f00"),
      ("f0&", "f0&"),
      ("f**", "f**"),
      ("fo#", "fo%23"),
      ("fo/o|bar", "fo%2Fo%7Cbar"),
      ("foo?bar", "foo%3Fbar"),
      ("foo<bar>", "foo%3Cbar%3E"),
    ]
  )
  func encodeAuthority(_ input: String, expected: String) {
    let encoded = PercentEncoding.encodeAuthority(input)
    #expect(encoded == expected)
  }
}
