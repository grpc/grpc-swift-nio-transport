# ``HTTP2ClientTransport/WrappedChannel``

## Topics

### Creating a wrapped channel

- ``init(takingOwnershipOf:config:serviceConfig:)``
- ``wrapping(channel:config:serviceConfig:)``
- ``wrapping(config:serviceConfig:makeChannel:)``
- ``ConfiguredChannel``
- ``Config``

### Making requests

- ``withStream(descriptor:options:_:)``
- ``config(forMethod:)``
- ``retryThrottle``

### Managing the connection

- ``connect()``
- ``beginGracefulShutdown()``
