# ``HTTP2ServerTransport/TransportServices``

## Topics

### Creating a transport

- ``init(address:transportSecurity:config:eventLoopGroup:)``
- ``http2NIOTS(address:transportSecurity:config:eventLoopGroup:)``
- ``Config``
- ``TransportSecurity``
- ``TLS``

### Serving

- ``listen(streamHandler:)``
- ``configure(context:)``
- ``listeningAddress``

### Shutting down

- ``beginGracefulShutdown()``
