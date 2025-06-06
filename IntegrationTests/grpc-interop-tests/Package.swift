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

let package = Package(
  name: "grpc-interop-tests",
  platforms: [.macOS("15.0")],
  dependencies: [
    .package(path: "../.."),
    .package(
      url: "https://github.com/grpc/grpc-swift-protobuf",
      from: "2.0.0"
    ),
    .package(
      url: "https://github.com/grpc/grpc-swift-extras",
      from: "2.0.0"
    ),
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      from: "1.5.0"
    ),
  ],
  targets: [
    .executableTarget(
      name: "grpc-interop-tests",
      dependencies: [
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "GRPCInteropTests", package: "grpc-swift-extras"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    )
  ]
)
