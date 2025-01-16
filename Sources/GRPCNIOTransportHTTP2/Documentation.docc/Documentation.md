# ``GRPCNIOTransportHTTP2``

An umbrella module providing high-performance HTTP/2 client and server transport
implementations built on top of SwiftNIO.

The module provides two variants of the client and server transport which differ in the
networking backend used by each. The two backends are:

1. `NIOPosix`, and
2. `NIOTransportServices`.

These correspond to two different modules provided by `grpc-swift-nio-transport`:

1. [`GRPCNIOTransportHTTP2Posix`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransporthttp2posix), and
2. [`GRPCNIOTransportHTTP2TransportServices`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransporthttp2transportservices).

This module, ``GRPCNIOTransportHTTP2``, re-exports the contents of both of these modules.

`GRPCNIOTransportHTTP2Posix` is available on all platforms, while
`GRPCNIOTransportHTTP2TransportServices` is only available on Darwin based platforms.
