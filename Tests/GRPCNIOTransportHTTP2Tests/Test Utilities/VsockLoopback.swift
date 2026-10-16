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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Whether a vsock connection can actually be established locally.
///
/// The vsock address family existing is enough to bind a listener, but connecting to
/// `VMADDR_CID_LOCAL` additionally needs the `vsock_loopback` transport (Linux 5.6+), so tests which
/// establish a connection need this stricter check. The transport can be either a loaded module or
/// built into the kernel; both appear under `/sys/module`, whereas `/proc/modules` lists only the
/// former.
func vsockLoopbackAvailable() -> Bool {
  #if os(Linux)
  return FileManager.default.fileExists(atPath: "/sys/module/vsock_loopback")
  #else
  return false
  #endif
}
