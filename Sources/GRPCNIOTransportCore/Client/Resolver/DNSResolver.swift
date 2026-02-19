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

private import Dispatch

#if canImport(Darwin)
private import Darwin
#elseif canImport(Android)
private import Android
#elseif canImport(Glibc)
private import Glibc
#elseif canImport(Musl)
private import Musl
#else
#error("The GRPCNIOTransportCore module was unable to identify your C library.")
#endif

/// An asynchronous non-blocking DNS resolver built on top of the libc `getaddrinfo` function.
@available(gRPCSwiftNIOTransport 2.0, *)
package enum DNSResolver {
  private static let dispatchQueue = DispatchQueue(
    label: "io.grpc.DNSResolver"
  )

  /// Resolves a hostname and port number to a list of socket addresses. This method is non-blocking.
  package static func resolve(host: String, port: Int) async throws -> [SocketAddress] {
    try Task.checkCancellation()

    return try await withCheckedThrowingContinuation { continuation in
      Self.dispatchQueue.async {
        do {
          let result = try Self.resolveBlocking(host: host, port: port)
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Resolves a hostname and port number to a list of socket addresses.
  ///
  /// Calls to `getaddrinfo` are blocking and this method calls `getaddrinfo` directly. Hence, this method is also blocking.
  private static func resolveBlocking(host: String, port: Int) throws -> [SocketAddress] {
    var result: UnsafeMutablePointer<addrinfo>?
    defer {
      if let result {
        // Release memory allocated by a successful call to getaddrinfo
        freeaddrinfo(result)
      }
    }

    var hints = addrinfo()
    #if os(Linux) && canImport(Glibc)
    hints.ai_socktype = CInt(SOCK_STREAM.rawValue)
    #else
    hints.ai_socktype = SOCK_STREAM
    #endif
    hints.ai_protocol = CInt(IPPROTO_TCP)

    let errorCode = getaddrinfo(host, String(port), &hints, &result)

    guard errorCode == 0, let result else {
      throw Self.GetAddrInfoError(code: errorCode)
    }

    return try Self.parseResult(result)
  }

  /// Parses the linked list of DNS results (`addrinfo`), returning an array of socket addresses.
  private static func parseResult(
    _ result: UnsafeMutablePointer<addrinfo>
  ) throws -> [SocketAddress] {
    var result = result
    var socketAddresses = [SocketAddress]()

    while true {
      let addressBytes: UnsafeRawPointer = UnsafeRawPointer(result.pointee.ai_addr)

      switch result.pointee.ai_family {
      case AF_INET:  // IPv4 address
        let ipv4AddressStructure = addressBytes.load(as: sockaddr_in.self)
        try socketAddresses.append(.ipv4(.init(ipv4AddressStructure)))
      case AF_INET6:  // IPv6 address
        let ipv6AddressStructure = addressBytes.load(as: sockaddr_in6.self)
        try socketAddresses.append(.ipv6(.init(ipv6AddressStructure)))
      default:
        ()
      }

      guard let nextResult = result.pointee.ai_next else { break }
      result = nextResult
    }

    return socketAddresses
  }

  /// Converts an address from a network format to a presentation format using `inet_ntop`.
  fileprivate static func convertAddressFromNetworkToPresentationFormat(
    addressPtr: UnsafeRawPointer,
    family: CInt,
    length: CInt
  ) throws -> String {
    var presentationAddressBytes = [CChar](repeating: 0, count: Int(length))

    return try presentationAddressBytes.withUnsafeMutableBufferPointer {
      (presentationAddressBytesPtr: inout UnsafeMutableBufferPointer<CChar>) throws -> String in

      // Convert
      let presentationAddressStringPtr = inet_ntop(
        family,
        addressPtr,
        presentationAddressBytesPtr.baseAddress!,
        socklen_t(length)
      )

      if let presentationAddressStringPtr {
        return String(cString: presentationAddressStringPtr)
      } else {
        throw Self.InetNetworkToPresentationError(errno: errno)
      }
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension DNSResolver {
  /// `Error` that may be thrown based on the error code returned by `getaddrinfo`.
  package struct GetAddrInfoError: Error, Hashable, CustomStringConvertible {
    package let description: String

    package init(code: CInt) {
      self.description = String(validatingCString: gai_strerror(code)) ?? "Unknown error: \(code)"
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension DNSResolver {
  /// `Error` that may be thrown based on the system error encountered by `inet_ntop`.
  package struct InetNetworkToPresentationError: Error, Hashable {
    package let errno: CInt

    package init(errno: CInt) {
      self.errno = errno
    }
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension SocketAddress.IPv4 {
  fileprivate init(_ address: sockaddr_in) throws {
    let presentationAddress = try withUnsafePointer(to: address.sin_addr) { addressPtr in
      return try DNSResolver.convertAddressFromNetworkToPresentationFormat(
        addressPtr: addressPtr,
        family: AF_INET,
        length: INET_ADDRSTRLEN
      )
    }

    self = .init(host: presentationAddress, port: Int(in_port_t(bigEndian: address.sin_port)))
  }
}

@available(gRPCSwiftNIOTransport 2.0, *)
extension SocketAddress.IPv6 {
  fileprivate init(_ address: sockaddr_in6) throws {
    let presentationAddress = try withUnsafePointer(to: address.sin6_addr) { addressPtr in
      return try DNSResolver.convertAddressFromNetworkToPresentationFormat(
        addressPtr: addressPtr,
        family: AF_INET6,
        length: INET6_ADDRSTRLEN
      )
    }

    // Preserve IPv6 scope ID (e.g., for link-local addresses like fe80::%eth0).
    // getaddrinfo sets sin6_scope_id but inet_ntop doesn't include it in the string.
    var host = presentationAddress
    #if !os(Windows)
    if address.sin6_scope_id != 0 {
      var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
      if if_indextoname(address.sin6_scope_id, &ifname) != nil {
        host = "\(presentationAddress)%\(String(cString: ifname))"
      }
    }
    #endif

    self = .init(host: host, port: Int(in_port_t(bigEndian: address.sin6_port)))
  }
}
