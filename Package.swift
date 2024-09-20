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
    url: "https://github.com/grpc/grpc-swift.git",
    branch: "main"
  ),
  .package(
    url: "https://github.com/apple/swift-nio.git",
    from: "2.65.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-http2.git",
    from: "1.32.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-transport-services.git",
    from: "1.15.0"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-ssl.git",
    from: "2.27.2"
  ),
  .package(
    url: "https://github.com/apple/swift-nio-extras.git",
    from: "1.4.0"
  ),
]

let defaultSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault")
]

let targets: [Target] = [
  // C-module for z-lib shims
  .target(
    name: "CGRPCZlib",
    dependencies: [],
    linkerSettings: [
      .linkedLibrary("z")
    ]
  ),

  // Core module containing shared compionents for the NIOPosix and NIOTS variants.
  .target(
    name: "GRPCNIOTransportCore",
    dependencies: [
      .product(name: "GRPCCore", package: "grpc-swift"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOHTTP2", package: "swift-nio-http2"),
      .product(name: "NIOExtras", package: "swift-nio-extras"),
      .target(name: "CGRPCZlib")
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
    ]
  ),

  // NIOPosix variant of the HTTP/2 transports.
  .target(
    name: "GRPCNIOTransportHTTP2Posix",
    dependencies: [
      .target(name: "GRPCNIOTransportCore"),
      .product(name: "GRPCCore", package: "grpc-swift"),
      .product(name: "NIOPosix", package: "swift-nio"),
    ],
    swiftSettings: defaultSwiftSettings
  ),

  // NIOTransportServices variant of the HTTP/2 transports.
  .target(
    name: "GRPCNIOTransportHTTP2TransportServices",
    dependencies: [
      .target(name: "GRPCNIOTransportCore"),
      .product(name: "GRPCCore", package: "grpc-swift"),
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
    ]
  )
]

let package = Package(
  name: "grpc-swift-nio-transport",
  products: products,
  dependencies: dependencies,
  targets: targets
)
