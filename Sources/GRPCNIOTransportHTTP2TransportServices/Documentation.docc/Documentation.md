# ``GRPCNIOTransportHTTP2TransportServices``

HTTP/2 client and server transports built on top of SwiftNIO's `NIOTransportServices` module.

## Overview

This module provides HTTP/2 transports for client and server built on top SwiftNIO's
`NIOTransportServices` module which provide TLS via Apple's Network framework.

The two transport types are:
- `HTTP2ClientTransport.TransportServices`, and
- `HTTP2ServerTransport.TransportServices`.

### Availability

These transports are available on the following platforms:

- macOS 15.0+
- iOS 18.0+
- tvOS 18.0+
- watchOS 11.0+


### Getting started

Bootstrapping a client or server is made easier using the `.http2NIOTS` shorthand:

```swift
// Create a server resolving "localhost:31415" using the default transport
// configuration and default TLS security configuration.
try await withGRPCClient(
  transport: try .http2NIOTS(
    target: .dns(host: "localhost", port: 31415),
    transportSecurity: .tls
  )
) { client in
  // ...
}

// Create a server listening on "127.0.0.1" on any available port
// using default plaintext security configuration.
try await withGRPCServer(
  transport: .http2NIOTS(
    address: .ipv4(host: "127.0.0.1", port: 0),
    transportSecurity: .plaintext,
    config: .defaults { config in
      config.http2.maxConcurrentStreams = 256
    }
  ),
  services: [...]
) { server in
  // ...
}
```
