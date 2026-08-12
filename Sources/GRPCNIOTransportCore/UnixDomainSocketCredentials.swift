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

/// Kernel-validated credentials of the process at the far end of a Unix domain socket.
///
/// The operating system records these when the connection is established, so they describe the
/// peer process as it was at connect time and aren't re-read per request.
@available(gRPCSwiftNIOTransport 2.10, *)
public struct UnixDomainSocketCredentials: Hashable, Sendable {
  /// The ID of the peer process.
  public var processID: ProcessID

  /// The ID of the effective user of the peer process.
  public var userID: UserID

  /// The ID of the effective group of the peer process.
  public var groupID: GroupID

  public init(processID: ProcessID, userID: UserID, groupID: GroupID) {
    self.processID = processID
    self.userID = userID
    self.groupID = groupID
  }

  /// The ID of a process.
  public struct ProcessID: Hashable, Sendable, RawRepresentable, ExpressibleByIntegerLiteral {
    public var rawValue: Int32

    public init(rawValue: Int32) {
      self.rawValue = rawValue
    }

    public init(integerLiteral value: Int32) {
      self.init(rawValue: value)
    }
  }

  /// The ID of a user.
  public struct UserID: Hashable, Sendable, RawRepresentable, ExpressibleByIntegerLiteral {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    public init(integerLiteral value: UInt32) {
      self.init(rawValue: value)
    }
  }

  /// The ID of a group.
  public struct GroupID: Hashable, Sendable, RawRepresentable, ExpressibleByIntegerLiteral {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    public init(integerLiteral value: UInt32) {
      self.init(rawValue: value)
    }
  }
}
