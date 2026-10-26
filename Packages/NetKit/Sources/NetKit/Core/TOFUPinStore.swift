import Foundation

/// A pinned certificate fingerprint (SHA-256 of the leaf certificate's DER encoding).
public struct CertificatePin: Hashable, Sendable, Codable {
    public let sha256: Data
    public let firstSeen: Date

    /// `sha256` must be 32 bytes.
    public init?(sha256: Data, firstSeen: Date = Date()) {
        guard sha256.count == 32 else { return nil }
        self.sha256 = sha256
        self.firstSeen = firstSeen
    }

    /// Colon-separated upper-case hex, as shown by certificate viewers.
    public var fingerprint: String { sha256.hexString(uppercase: true, separator: ":") }
}

/// Outcome of a trust-on-first-use check.
public enum TOFUResult: Sendable, Equatable {
    /// No pin existed; the presented fingerprint was stored.
    case pinnedOnFirstUse
    /// The presented fingerprint equals the stored pin.
    case matched
    /// A different certificate was pinned for this identifier. Do not connect.
    case mismatch(pinned: CertificatePin)
}

/// Stores certificate pins keyed by a stable identifier (e.g. the Hue bridge id).
/// Identifiers are compared case-insensitively. A persistent implementation (Keychain) lives
/// in the app; NetKit ships ``InMemoryTOFUPinStore`` for tests and previews.
public protocol TOFUPinStore: Sendable {
    func pin(for identifier: String) async -> CertificatePin?
    func setPin(_ pin: CertificatePin, for identifier: String) async
    func removePin(for identifier: String) async
    /// Compares `sha256` with the stored pin, pinning it if none exists. Implementations should
    /// make this atomic.
    func verifyOrPin(sha256: Data, for identifier: String) async -> TOFUResult
}

extension TOFUPinStore {
    /// Default (non-atomic) implementation built from the other requirements.
    public func verifyOrPin(sha256: Data, for identifier: String) async -> TOFUResult {
        if let existing = await pin(for: identifier) {
            return existing.sha256 == sha256 ? .matched : .mismatch(pinned: existing)
        }
        guard let pin = CertificatePin(sha256: sha256) else {
            return .mismatch(pinned: CertificatePin(sha256: Data(repeating: 0, count: 32))!)
        }
        await setPin(pin, for: identifier)
        return .pinnedOnFirstUse
    }
}

/// In-memory pin store (atomic `verifyOrPin` via actor isolation).
public actor InMemoryTOFUPinStore: TOFUPinStore {
    private var pins: [String: CertificatePin]

    public init(pins: [String: CertificatePin] = [:]) {
        self.pins = Dictionary(pins.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public func pin(for identifier: String) -> CertificatePin? { pins[identifier.lowercased()] }

    public func setPin(_ pin: CertificatePin, for identifier: String) { pins[identifier.lowercased()] = pin }

    public func removePin(for identifier: String) { pins[identifier.lowercased()] = nil }

    public func verifyOrPin(sha256: Data, for identifier: String) -> TOFUResult {
        let key = identifier.lowercased()
        if let existing = pins[key] {
            return existing.sha256 == sha256 ? .matched : .mismatch(pinned: existing)
        }
        guard let pin = CertificatePin(sha256: sha256) else {
            // Malformed fingerprint: never pin it, never trust it.
            return .mismatch(pinned: CertificatePin(sha256: Data(repeating: 0, count: 32))!)
        }
        pins[key] = pin
        return .pinnedOnFirstUse
    }

    public var allIdentifiers: [String] { Array(pins.keys).sorted() }
}

/// PEM helpers (pure Foundation; used by ``TrustEvaluator`` to load Signify root CAs).
public enum PEM {
    /// Extracts the DER bytes of every `-----BEGIN CERTIFICATE-----` block in `pem`.
    public static func certificates(from pem: String) -> [Data] {
        blocks(labelled: "CERTIFICATE", in: pem)
    }

    /// Extracts DER bytes of every PEM block with the given label.
    public static func blocks(labelled label: String, in pem: String) -> [Data] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        var result: [Data] = []
        var remainder = Substring(pem)
        while let b = remainder.range(of: begin) {
            let afterBegin = remainder[b.upperBound...]
            guard let e = afterBegin.range(of: end) else { break }
            let body = afterBegin[..<e.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)), !der.isEmpty { result.append(der) }
            remainder = afterBegin[e.upperBound...]
        }
        return result
    }
}
