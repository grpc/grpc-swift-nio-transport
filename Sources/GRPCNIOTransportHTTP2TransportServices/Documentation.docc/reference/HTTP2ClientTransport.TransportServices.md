# ``HTTP2ClientTransport/TransportServices``

## Topics

### Creating a transport

- ``init(target:transportSecurity:config:resolverRegistry:serviceConfig:eventLoopGroup:)``
- ``http2NIOTS(target:transportSecurity:config:resolverRegistry:serviceConfig:eventLoopGroup:)``
- ``Config``
- ``TransportSecurity``
- ``TLS``

### Making requests

- ``withStream(descriptor:options:_:)``
- ``config(forMethod:)``
- ``retryThrottle``

### Managing the connection

- ``connect()``
- ``beginGracefulShutdown()``
