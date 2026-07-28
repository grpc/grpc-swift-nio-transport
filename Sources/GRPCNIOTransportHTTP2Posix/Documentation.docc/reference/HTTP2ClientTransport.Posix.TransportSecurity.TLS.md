# ``HTTP2ClientTransport/Posix/TransportSecurity/TLS``

## Topics

### Creating a TLS configuration

- ``init(certificateChain:privateKey:serverCertificateVerification:trustRoots:)``
- ``defaults``
- ``defaults(configure:)``
- ``mTLS(certificateChain:privateKey:configure:)``

### Certificates and keys

- ``certificateChain``
- ``privateKey``
- ``certificateReloader``

### Verifying the server

- ``serverCertificateVerification``
- ``trustRoots``
- ``customVerificationCallback``
