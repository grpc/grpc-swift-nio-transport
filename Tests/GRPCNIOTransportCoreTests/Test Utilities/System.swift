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

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum System {
  static var isWindows: Bool {
    #if os(Windows)
    true
    #else
    false
    #endif
  }

  /// The loopback interface name for the current platform, or `nil` on Windows.
  static var loopbackInterfaceName: String? {
    #if os(Windows)
    nil
    #elseif canImport(Darwin)
    "lo0"
    #else
    "lo"
    #endif
  }

  /// Returns `true` if the named network interface exists and is valid on this platform.
  static func isValidInterface(_ name: String) -> Bool {
    #if os(Windows)
    false
    #else
    if_nametoindex(name) != 0
    #endif
  }
}
