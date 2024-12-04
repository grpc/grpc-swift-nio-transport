# ``GRPCNIOTransportHTTP2Posix``

HTTP/2 client and server transports built on top of SwiftNIO's `NIOPosix` module.

## Overview

This module provides HTTP/2 transports for client and server built on top SwiftNIO's `NIOPosix`
module and uses SwiftNIO's `NIOSSL` module to provide TLS.

The two transport types are:
- `HTTP2ClientTransport.Posix`, and
- `HTTP2ServerTransport.Posix`.

### Availability

These transports are available on the following platforms:

- Linux (Ubuntu, CentOS, Amazon Linux, Red Hat Universal Base Image)
- macOS 15.0+
- iOS 18.0+
- tvOS 18.0+
- watchOS 11.0+


### Getting started

Bootstrapping a client or server is made easier using the `.http2NIOPosix` shorthand:

```swift
// Create a server resolving "localhost:31415" using the default transport
// configuration and default TLS security configuration.
try await withGRPCClient(
  transport: try .http2NIOPosix(
    target: .dns(host: "localhost", port: 31415),
    transportSecurity: .tls
  )
) { client in
  // ...
}

// Create a plaintext server listening on "127.0.0.1" on any available port
// modifying the default configuration to set max concurrent streams to 256.
try await withGRPCServer(
  transport: .http2NIOPosix(
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
