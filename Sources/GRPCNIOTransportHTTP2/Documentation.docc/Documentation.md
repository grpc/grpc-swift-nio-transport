# ``GRPCNIOTransportHTTP2``

An umbrella module providing high-performance HTTP/2 client and server transport
implementations built on top of SwiftNIO.

## Overview

The module provides two variants of the client and server transport which differ in the
networking backend used by each: `NIOPosix` and `NIOTransportServices`. These correspond to two
modules provided by `grpc-swift-nio-transport`:
[`GRPCNIOTransportHTTP2Posix`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransporthttp2posix),
providing `HTTP2ClientTransport.Posix` and `HTTP2ServerTransport.Posix`; and
[`GRPCNIOTransportHTTP2TransportServices`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransporthttp2transportservices),
providing `HTTP2ClientTransport.TransportServices` and `HTTP2ServerTransport.TransportServices`.

This module, ``GRPCNIOTransportHTTP2``, re-exports the contents of both of these modules.

`GRPCNIOTransportHTTP2Posix` is available on all platforms, while
`GRPCNIOTransportHTTP2TransportServices` is only available on Darwin-based platforms.

## See Also

- [`HTTP2ClientTransport`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/http2clienttransport)
- [`HTTP2ServerTransport`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/http2servertransport)
- [`ListeningServerTransport`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/listeningservertransport)
- [`ResolvableTarget`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/resolvabletarget)
- [`ResolvableTargets`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/resolvabletargets)
- [`NameResolvers`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/nameresolvers)
- [`NameResolverRegistry`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/nameresolverregistry)
- [`NameResolverFactory`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/nameresolverfactory)
- [`NameResolver`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/nameresolver)
- [`NameResolutionResult`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/nameresolutionresult)
- [`SocketAddress`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/socketaddress)
- [`Endpoint`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/endpoint)
- [`TLSConfig`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/tlsconfig)
- [`GRPCNIOTransportBytes`](https://swiftpackageindex.com/grpc/grpc-swift-nio-transport/documentation/grpcniotransportcore/grpcniotransportbytes)
