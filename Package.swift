// swift-tools-version: 6.0
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

import PackageDescription

let products: [Product] = [
  .library(
    name: "GRPCNIOTransportHTTP2",
    targets: ["GRPCNIOTransportHTTP2"]
  ),
  .library(
    name: "GRPCNIOTransportHTTP2Posix",
    targets: ["GRPCNIOTransportHTTP2Posix"]
  ),
  .library(
    name: "GRPCNIOTransportHTTP2TransportServices",
    targets: ["GRPCNIOTransportHTTP2TransportServices"]
  ),
]

let dependencies: [Package.Dependency] = [
  .package(
    url: "https://github.com/grpc/grpc-swift-2.git",
    from: "2.0.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio.git",
    from: "2.78.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-http2.git",
    from: "1.38.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-transport-services.git",
    from: "1.20.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-ssl.git",
    from: "2.34.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-extras.git",
    from: "1.27.0"
  ),
  .package(
    url: "https://github.com/apple/swift-certificates.git",
    from: "1.14.0"
  ),
  .package(
    url: "https://github.com/apple/swift-asn1.git",
    from: "1.0.0"
  ),
]

// -------------------------------------------------------------------------------------------------

// This adds some build settings which allow us to map "@available(gRPCSwiftNIOTransport 2.x, *)" to
// the appropriate OS platforms.
let nextMinorVersion = 3
let availabilitySettings: [SwiftSetting] = (0 ... nextMinorVersion).map { minor in
  let name = "gRPCSwiftNIOTransport"
  let version = "2.\(minor)"
  let platforms = "macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
  let setting = "AvailabilityMacro=\(name) \(version):\(platforms)"
  return .enableExperimentalFeature(setting)
}

let defaultSwiftSettings: [SwiftSetting] =
  availabilitySettings + [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
  ]

// -------------------------------------------------------------------------------------------------

let targets: [Target] = [
  // C-module for z-lib shims
  .target(
    name: "CGRPCNIOTransportZlib",
    dependencies: [],
    linkerSettings: [
      .linkedLibrary("z")
    ]
  ),

  // Core module containing shared components for the NIOPosix and NIOTS variants.
  .target(
    name: "GRPCNIOTransportCore",
    dependencies: [
      .product(name: "GRPCCore", package: "grpc-swift-2"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOHTTP2", package: "swift-nio-http2"),
      .product(name: "NIOExtras", package: "swift-nio-extras"),
      .target(name: "CGRPCNIOTransportZlib"),
    ],
    swiftSettings: defaultSwiftSettings
  ),
  .testTarget(
    name: "GRPCNIOTransportCoreTests",
    dependencies: [
      .target(name: "GRPCNIOTransportCore"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOEmbedded", package: "swift-nio"),
      .product(name: "NIOTestUtils", package: "swift-nio"),
    ],
    swiftSettings: defaultSwiftSettings
  ),

  // NIOPosix variant of the HTTP/2 transports.
  .target(
    name: "GRPCNIOTransportHTTP2Posix",
    dependencies: [
      .target(name: "GRPCNIOTransportCore"),
      .product(name: "GRPCCore", package: "grpc-swift-2"),
      .product(name: "NIOPosix", package: "swift-nio"),
      .product(name: "NIOSSL", package: "swift-nio-ssl"),
      .product(name: "X509", package: "swift-certificates"),
      .product(name: "SwiftASN1", package: "swift-asn1"),
      .product(name: "NIOCertificateReloading", package: "swift-nio-extras"),
    ],
    swiftSettings: defaultSwiftSettings
  ),

  // NIOTransportServices variant of the HTTP/2 transports.
  .target(
    name: "GRPCNIOTransportHTTP2TransportServices",
    dependencies: [
      .target(name: "GRPCNIOTransportCore"),
      .product(name: "GRPCCore", package: "grpc-swift-2"),
      .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
    ],
    swiftSettings: defaultSwiftSettings
  ),

  // Umbrella module exporting NIOPosix and NIOTransportServices variants.
  .target(
    name: "GRPCNIOTransportHTTP2",
    dependencies: [
      .target(name: "GRPCNIOTransportHTTP2Posix"),
      .target(name: "GRPCNIOTransportHTTP2TransportServices"),
    ],
    swiftSettings: defaultSwiftSettings
  ),
  .testTarget(
    name: "GRPCNIOTransportHTTP2Tests",
    dependencies: [
      .target(name: "GRPCNIOTransportHTTP2"),
      .product(name: "GRPCCore", package: "grpc-swift-2"),
      .product(name: "X509", package: "swift-certificates"),
      .product(name: "NIOSSL", package: "swift-nio-ssl"),
    ],
    swiftSettings: defaultSwiftSettings
  ),
]

let package = Package(
  name: "grpc-swift-nio-transport",
  products: products,
  dependencies: dependencies,
  targets: targets
)
