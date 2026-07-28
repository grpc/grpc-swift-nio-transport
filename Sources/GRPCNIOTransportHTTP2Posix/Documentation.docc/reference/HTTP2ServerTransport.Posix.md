# ``HTTP2ServerTransport/Posix``

## Topics

### Creating a transport

- ``init(address:transportSecurity:config:eventLoopGroup:)``
- ``http2NIOPosix(address:transportSecurity:config:eventLoopGroup:)``
- ``init(listeningSocketDescriptor:transportSecurity:config:eventLoopGroup:)``
- ``http2NIOPosix(listeningSocketDescriptor:transportSecurity:config:eventLoopGroup:)``
- ``Config``
- ``TransportSecurity``

### Serving

- ``listen(streamHandler:)``
- ``configure(context:)``
- ``listeningAddress``
- ``Context``

### Shutting down

- ``beginGracefulShutdown()``
