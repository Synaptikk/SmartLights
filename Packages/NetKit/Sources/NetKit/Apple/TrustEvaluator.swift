#if canImport(Security) && canImport(CryptoKit) && canImport(Darwin)
import CryptoKit
import Foundation
import OSLog
@preconcurrency import Security

/// Why a server certificate was rejected.
public enum TrustRejection: Sendable, Equatable {
    case noCertificate
    /// Leaf CN differs from the expected identifier (e.g. the Hue bridge id).
    case commonNameMismatch(found: String?)
    /// Chain did not verify against the anchors and no TOFU fallback applied.
    case chainInvalid(String)
    /// A different certificate is already pinned for this identifier.
    case pinMismatch(pinnedFingerprint: String)
    /// Not self-issued, so the TOFU fallback does not apply.
    case notSelfSigned
}

public enum TrustDecision: Sendable, Equatable {
    /// Chained to one of the custom anchors and the CN matched.
    case trustedByAnchor
    /// Self-signed leaf accepted via trust-on-first-use (`firstUse` = the pin was just created).
    case trustedByPin(firstUse: Bool)
    case rejected(TrustRejection)

    public var isTrusted: Bool {
        if case .rejected = self { return false }
        return true
    }
}

/// Server-trust evaluation for devices with private CAs (Hue: Signify roots, CN == bridge id;
/// see research_ios_platform.md A6 and PLAN.md 4.4):
/// 1. Evaluate with `SecPolicyCreateBasicX509()` (hostname is ignored: we connect by IP) against
///    the supplied anchors only; trusted + leaf CN == expected id => `.trustedByAnchor`.
/// 2. Otherwise, if allowed, accept a self-signed leaf (old Hue firmware) whose CN == expected id,
///    pinning its SHA-256 per identifier in the ``TOFUPinStore``.
public final class TrustEvaluator: Sendable {
    public let anchorCertificatesDER: [Data]
    /// Expected leaf CN, compared case-insensitively (Hue bridge id, 16 hex chars).
    public let expectedIdentifier: String
    public let pinStore: (any TOFUPinStore)?
    /// Enables the TOFU fallback for self-signed leaves (requires `pinStore`).
    public let allowSelfSignedTOFU: Bool
    /// When true (default) a self-signed leaf is only accepted if its CN equals `expectedIdentifier`.
    public let requireSelfSignedCommonNameMatch: Bool

    public init(anchorCertificatesDER: [Data], expectedIdentifier: String, pinStore: (any TOFUPinStore)? = nil,
                allowSelfSignedTOFU: Bool = true, requireSelfSignedCommonNameMatch: Bool = true) {
        self.anchorCertificatesDER = anchorCertificatesDER
        self.expectedIdentifier = expectedIdentifier
        self.pinStore = pinStore
        self.allowSelfSignedTOFU = allowSelfSignedTOFU
        self.requireSelfSignedCommonNameMatch = requireSelfSignedCommonNameMatch
    }

    /// Builds the evaluator from PEM text (e.g. the contents of `hue-roots.pem`).
    public convenience init(anchorsPEM: String, expectedIdentifier: String, pinStore: (any TOFUPinStore)? = nil,
                            allowSelfSignedTOFU: Bool = true, requireSelfSignedCommonNameMatch: Bool = true) {
        self.init(anchorCertificatesDER: PEM.certificates(from: anchorsPEM), expectedIdentifier: expectedIdentifier,
                  pinStore: pinStore, allowSelfSignedTOFU: allowSelfSignedTOFU,
                  requireSelfSignedCommonNameMatch: requireSelfSignedCommonNameMatch)
    }

    public func evaluate(_ trust: SecTrust) async -> TrustDecision {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return .rejected(.noCertificate)
        }
        let commonName = Self.commonName(of: leaf)
        let commonNameMatches = commonName.map {
            $0.caseInsensitiveCompare(expectedIdentifier) == .orderedSame
        } ?? false

        var anchorFailure = "no anchors configured"
        let anchors = anchorCertificatesDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        if !anchors.isEmpty {
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                return commonNameMatches ? .trustedByAnchor : .rejected(.commonNameMismatch(found: commonName))
            }
            anchorFailure = error.map { String(describing: $0) } ?? "untrusted"
        }

        guard allowSelfSignedTOFU, let pinStore else { return .rejected(.chainInvalid(anchorFailure)) }
        guard Self.isSelfIssued(leaf) else { return .rejected(.chainInvalid(anchorFailure)) }
        if requireSelfSignedCommonNameMatch, !commonNameMatches {
            return .rejected(.commonNameMismatch(found: commonName))
        }
        let digest = Self.sha256(of: leaf)
        switch await pinStore.verifyOrPin(sha256: digest, for: expectedIdentifier) {
        case .pinnedOnFirstUse:
            NetKitLog.trust.info("TOFU pinned self-signed certificate for \(self.expectedIdentifier, privacy: .public)")
            return .trustedByPin(firstUse: true)
        case .matched:
            return .trustedByPin(firstUse: false)
        case .mismatch(let pinned):
            NetKitLog.trust.error("Pinned certificate mismatch for \(self.expectedIdentifier, privacy: .public)")
            return .rejected(.pinMismatch(pinnedFingerprint: pinned.fingerprint))
        }
    }

    /// Answers a URLSession server-trust challenge; other challenge types get default handling.
    public func handle(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let decision = await evaluate(trust)
        guard decision.isTrusted else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    // MARK: - Certificate helpers

    public static func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess, let name else { return nil }
        return name as String
    }

    public static func isSelfIssued(_ certificate: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) else { return false }
        return (issuer as Data) == (subject as Data)
    }

    public static func sha256(of certificate: SecCertificate) -> Data {
        let der = SecCertificateCopyData(certificate) as Data
        return Data(SHA256.hash(data: der))
    }
}

/// `URLSessionDelegate` that routes server-trust challenges to a ``TrustEvaluator``. Use one
/// session per device (the evaluator knows the expected id).
public final class TrustingSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    public let evaluator: TrustEvaluator

    public init(evaluator: TrustEvaluator) {
        self.evaluator = evaluator
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await evaluator.handle(challenge)
    }

    /// Convenience: an ephemeral session using this delegate.
    public static func session(evaluator: TrustEvaluator,
                               configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration, delegate: TrustingSessionDelegate(evaluator: evaluator), delegateQueue: nil)
    }
}
#endif
