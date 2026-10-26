import Foundation

/// What the running binary was signed with, as far as it can be observed on iOS.
struct EntitlementsInfo: Sendable, Equatable {
    enum Source: String, Sendable {
        case codeSignature = "code signature"
        case provisioningProfile = "embedded.mobileprovision"
        case infoPlistFlag = "Info.plist flag SLMulticastEntitlement"
        case unavailable = "unavailable"
    }

    var source: Source
    /// Sorted entitlement keys (values omitted: they can contain team/app identifiers only, but
    /// there is no need to export them).
    var keys: [String]
    /// nil = could not be determined.
    var multicast: Bool?
    var homeKit: Bool?
    var note: String?

    static func unavailable(_ note: String) -> EntitlementsInfo {
        EntitlementsInfo(source: .unavailable, keys: [], multicast: nil, homeKit: nil, note: note)
    }
}

/// Reads the app's own entitlements.
///
/// `SecTaskCopyValueForEntitlement` is not part of the public iOS SDK, so instead this parses the
/// entitlements blob embedded in the main executable's code signature (`LC_CODE_SIGNATURE` ->
/// SuperBlob -> slot 5, XML plist). Fallbacks: `embedded.mobileprovision` (development / ad-hoc
/// builds; App Store/TestFlight builds have none), then an optional Info.plist flag
/// `SLMulticastEntitlement` (Bool or "YES"/"NO", e.g. set from a build setting).
/// Synchronous file I/O: call off the main actor (`DiagnosticsProbe.withTimeout`).
enum EntitlementsReader {
    static let multicastKey = "com.apple.developer.networking.multicast"
    static let homeKitKey = "com.apple.developer.homekit"
    static let infoPlistFlagKey = "SLMulticastEntitlement"

    static func read() -> EntitlementsInfo {
        let bundle = Bundle.main
        if let url = bundle.executableURL, let dict = codeSignatureEntitlements(executable: url) {
            return make(dict, source: .codeSignature)
        }
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let dict = provisioningProfileEntitlements(url) {
            return make(dict, source: .provisioningProfile,
                        note: "From the provisioning profile (allowed entitlements), not the signature")
        }
        if let flag = bundle.object(forInfoDictionaryKey: infoPlistFlagKey) {
            let value: Bool? = switch flag {
            case let b as Bool: b
            case let n as NSNumber: n.boolValue
            case let s as String: ["1", "yes", "true"].contains(s.lowercased())
            default: nil
            }
            return EntitlementsInfo(source: .infoPlistFlag, keys: [], multicast: value, homeKit: nil,
                                    note: "Build-setting flag, not verified against the signature")
        }
        #if targetEnvironment(simulator)
        return .unavailable("Simulator build (unsigned); entitlements are not embedded")
        #else
        return .unavailable("No entitlements blob found in the code signature")
        #endif
    }

    private static func make(_ dict: [String: Any], source: EntitlementsInfo.Source, note: String? = nil) -> EntitlementsInfo {
        func flag(_ key: String) -> Bool {
            guard let value = dict[key] else { return false }
            return (value as? Bool) ?? true
        }
        return EntitlementsInfo(source: source, keys: dict.keys.sorted(),
                                multicast: flag(multicastKey), homeKit: flag(homeKitKey), note: note)
    }

    // MARK: - Mach-O code signature

    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let lcCodeSignature: UInt32 = 0x1D
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsBlobMagic: UInt32 = 0xFADE_7171
    private static let entitlementsSlot: UInt32 = 5

    static func codeSignatureEntitlements(executable url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let r = ByteReader(data: data)
        guard let magicBE = r.u32be(0) else { return nil }

        var slice = 0
        if magicBE == fatMagic || magicBE == fatMagic64 {
            let is64 = magicBE == fatMagic64
            guard let count = r.u32be(4) else { return nil }
            let entrySize = is64 ? 32 : 20
            var chosen: Int?
            for i in 0..<Int(min(count, 32)) {
                let base = 8 + i * entrySize
                guard let cpu = r.u32be(base) else { return nil }
                let offset: Int? = is64 ? r.u64be(base + 8).flatMap { Int(exactly: $0) } : r.u32be(base + 8).map { Int($0) }
                guard let offset else { return nil }
                if chosen == nil { chosen = offset }
                if cpu == cpuTypeARM64 { chosen = offset; break }
            }
            guard let chosen else { return nil }
            slice = chosen
        }

        guard r.u32le(slice) == machMagic64, let ncmds = r.u32le(slice + 16) else { return nil }
        var cursor = slice + 32 // sizeof(mach_header_64)
        for _ in 0..<Int(min(ncmds, 4_096)) {
            guard let cmd = r.u32le(cursor), let size = r.u32le(cursor + 4), size >= 8 else { return nil }
            if cmd == lcCodeSignature {
                guard let dataOffset = r.u32le(cursor + 8) else { return nil }
                return superBlobEntitlements(r, at: slice + Int(dataOffset))
            }
            cursor += Int(size)
        }
        return nil
    }

    private static func superBlobEntitlements(_ r: ByteReader, at start: Int) -> [String: Any]? {
        guard r.u32be(start) == superBlobMagic, let count = r.u32be(start + 8) else { return nil }
        for i in 0..<Int(min(count, 64)) {
            let entry = start + 12 + i * 8
            guard let type = r.u32be(entry), let offset = r.u32be(entry + 4) else { return nil }
            guard type == entitlementsSlot else { continue }
            let blob = start + Int(offset)
            guard r.u32be(blob) == entitlementsBlobMagic, let length = r.u32be(blob + 4), length > 8,
                  blob + Int(length) <= r.data.count else { return nil }
            return plistDictionary(r.data.subdata(in: (blob + 8)..<(blob + Int(length))))
        }
        return nil
    }

    // MARK: - Provisioning profile

    static func provisioningProfileEntitlements(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = plistDictionary(data.subdata(in: start.lowerBound..<end.upperBound))
        return plist?["Entitlements"] as? [String: Any]
    }

    private static func plistDictionary(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

/// Bounds-checked integer reads from a zero-based `Data`.
private struct ByteReader {
    let data: Data

    func u32le(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func u32be(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func u64be(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
