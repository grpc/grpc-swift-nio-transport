# ``HTTP2ServerTransport/Posix/TransportSecurity/TLS``

## Topics

### Creating a TLS configuration

- ``init(certificateChain:privateKey:clientCertificateVerification:trustRoots:requireALPN:)``
- ``defaults(certificateChain:privateKey:configure:)``
- ``mTLS(certificateChain:privateKey:configure:)``

### Certificates and keys

- ``certificateChain``
- ``privateKey``
- ``certificateReloader``

### Verifying clients

- ``clientCertificateVerification``
- ``trustRoots``
- ``customVerificationCallback``
- ``requireALPN``
