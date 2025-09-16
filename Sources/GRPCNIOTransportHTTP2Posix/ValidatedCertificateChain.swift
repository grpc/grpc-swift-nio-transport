internal import NIOSSL
internal import SwiftASN1
internal import X509

@available(gRPCSwiftNIOTransport 2.2, *)
extension NIOSSL.ValidatedCertificateChain {
  // The precondition holds because the `NIOSSL.ValidatedCertificateChain` always contains one `NIOSSLCertificate`.
  func usingX509Certificates() throws -> X509.ValidatedCertificateChain {
    return .init(
      uncheckedCertificateChain: try self.map {
        let derBytes = try $0.toDERBytes()
        return try Certificate(derEncoded: derBytes)
      }
    )
  }
}
