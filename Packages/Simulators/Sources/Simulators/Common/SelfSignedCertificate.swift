import Crypto
import Foundation
import NIOSSL
import X509

/// A freshly generated self-signed P-256 certificate, like an older Hue bridge's
/// (subject CN == issuer CN == bridge id).
public struct SelfSignedCertificate: Sendable {
    public let certificatePEM: String
    public let privateKeyPEM: String
    public let commonName: String
    /// DER bytes of the certificate (what a client sees on the wire).
    public let certificateDER: [UInt8]

    public init(commonName: String, validDays: Int = 3650) throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CountryName("NL")
            OrganizationName("Philips Hue")
            CommonName(commonName)
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(Double(validDays) * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                KeyUsage(digitalSignature: true, keyCertSign: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(commonName.lowercased())])
            },
            issuerPrivateKey: .init(key)
        )
        let pem = try cert.serializeAsPEM()
        self.certificatePEM = pem.pemString
        self.certificateDER = pem.derBytes
        self.privateKeyPEM = key.pemRepresentation
        self.commonName = commonName
    }

    func makeServerContext() throws -> NIOSSLContext {
        let cert = try NIOSSLCertificate(bytes: Array(certificatePEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        var cfg = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        cfg.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: cfg)
    }
}
