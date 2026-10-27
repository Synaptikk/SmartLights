import Foundation
import LightCore

/// A user-defined group of lights from any brands, controlled as one (T2.8).
///
/// Unlike rooms, a light can be in any number of groups. Members are stable light ids (never
/// IPs); lights that are not loaded right now are kept and skipped when sending.
struct LightGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Ordered member lights.
    var lightIDs: [LightID]
    /// Fade applied to every command sent to the group; nil = each provider's default.
    var transitionMilliseconds: Int?
    /// Light Sync: while set, this light's state is mirrored to the other members.
    /// The source does not have to be a member.
    var syncSourceID: LightID?

    init(
        id: UUID = UUID(),
        name: String,
        lightIDs: [LightID] = [],
        transitionMilliseconds: Int? = nil,
        syncSourceID: LightID? = nil
    ) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
        self.transitionMilliseconds = transitionMilliseconds
        self.syncSourceID = syncSourceID
    }

    var transition: Duration? {
        transitionMilliseconds.map { .milliseconds($0) }
    }

    var isSyncing: Bool { syncSourceID != nil }

    /// Lights that follow the sync source (members other than the source).
    var syncTargets: [LightID] {
        guard let syncSourceID else { return [] }
        return lightIDs.filter { $0 != syncSourceID }
    }
}

extension TransitionOption {
    /// The option matching a stored group transition (`.providerDefault` for nil or unknown values).
    init(milliseconds: Int?) {
        self = Self.allCases.first { $0.milliseconds == milliseconds } ?? .providerDefault
    }

    var milliseconds: Int? {
        guard let duration else { return nil }
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
