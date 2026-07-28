# ``HTTP2ClientTransport/Posix``

## Topics

### Creating a transport

- ``init(target:transportSecurity:config:resolverRegistry:serviceConfig:eventLoopGroup:)``
- ``http2NIOPosix(target:transportSecurity:config:resolverRegistry:serviceConfig:eventLoopGroup:)``
- ``Config``
- ``TransportSecurity``

### Making requests

- ``withStream(descriptor:options:_:)``
- ``config(forMethod:)``
- ``retryThrottle``

### Managing the connection

- ``connect()``
- ``beginGracefulShutdown()``
