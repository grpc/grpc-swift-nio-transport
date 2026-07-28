# ``GRPCNIOTransportHTTP2``

An umbrella module providing high-performance HTTP/2 client and server transport
implementations built on top of SwiftNIO.

## Overview

The module provides two variants of the client and server transport which differ in the
networking backend used by each: `NIOPosix` and `NIOTransportServices`. These correspond to two
modules provided by `grpc-swift-nio-transport`: `GRPCNIOTransportHTTP2Posix`, providing
``HTTP2ClientTransport/Posix`` and ``HTTP2ServerTransport/Posix``; and
`GRPCNIOTransportHTTP2TransportServices`, providing ``HTTP2ClientTransport/TransportServices``
and ``HTTP2ServerTransport/TransportServices``.

This module, ``GRPCNIOTransportHTTP2``, re-exports the contents of both of these modules.

`GRPCNIOTransportHTTP2Posix` is available on all platforms, while
`GRPCNIOTransportHTTP2TransportServices` is only available on Darwin-based platforms.

## Topics

### Client and server transports

- ``HTTP2ClientTransport``
- ``HTTP2ServerTransport``

### Transport extensions

- ``ListeningServerTransport``

### Name resolution

- ``ResolvableTarget``
- ``ResolvableTargets``
- ``NameResolvers``
- ``NameResolverRegistry``
- ``NameResolverFactory``
- ``NameResolver``
- ``NameResolutionResult``

### Addresses

- ``SocketAddress``
- ``Endpoint``

### TLS

- ``TLSConfig``

### Message data

- ``GRPCNIOTransportBytes``
