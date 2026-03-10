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
private import Darwin
#elseif canImport(Android)
private import Android
#elseif canImport(Glibc)
private import Glibc
#elseif canImport(Musl)
private import Musl
#endif

#if !os(Windows)
/// Resolves an IPv6 scope ID to its interface name.
/// - Parameter scopeID: The numeric scope ID from `sin6_scope_id`
/// - Returns: The interface name (e.g., "eth0"), or empty string if resolution fails
@available(gRPCSwiftNIOTransport 2.0, *)
internal func resolveScopeID(_ scopeID: UInt32) -> String {
  String(unsafeUninitializedCapacity: Int(IF_NAMESIZE)) { buffer in
    guard let baseAddress = buffer.baseAddress,
          let ptr = if_indextoname(scopeID, baseAddress) else {
      return 0
    }
    return strlen(ptr)
  }
}
#endif
