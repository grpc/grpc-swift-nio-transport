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
/// - Returns: The interface name (e.g., "eth0"), or `nil` if resolution fails
@available(gRPCSwiftNIOTransport 2.0, *)
internal func resolveScopeID(_ scopeID: UInt32) -> String? {
  let name = String(unsafeUninitializedCapacity: Int(IF_NAMESIZE)) { buffer in
    guard let baseAddress = buffer.baseAddress,
          let ptr = if_indextoname(scopeID, baseAddress) else {
      return 0
    }
    return strlen(ptr)
  }
  return name.isEmpty ? nil : name
}

/// Appends the scope ID interface name to an IPv6 host string if needed.
///
/// `inet_ntop` does not include the scope ID in its output, so this function
/// reconstructs the `%scope` suffix from the raw `sin6_scope_id` value.
/// - Parameters:
///   - host: The IPv6 host string to modify in place.
///   - scopeID: The numeric scope ID from `sin6_scope_id`.
@available(gRPCSwiftNIOTransport 2.0, *)
internal func appendScopeIDIfNeeded(to host: inout String, scopeID: UInt32) {
  if scopeID != 0 && !host.utf8.contains(UInt8(ascii: "%")) {
    if let scopeName = resolveScopeID(scopeID) {
      host += "%\(scopeName)"
    }
  }
}
#endif
