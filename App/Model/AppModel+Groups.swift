import Foundation
import LightCore
import SwiftUI // MutableCollection.move(fromOffsets:toOffset:)

// Cross-brand groups (T2.8): any lights from any brands, controlled equally. Group commands go
// through the coalescer as one group send, which `ProviderRegistry.sendGroup` splits by brand
// and dispatches to every provider concurrently (native groups where a provider has them).

// MARK: - Queries

extension AppModel {
    func group(_ id: LightGroup.ID) -> LightGroup? {
        groups.first { $0.id == id }
    }

    /// Member lights that are currently known, in group order.
    func lights(inGroup id: LightGroup.ID) -> [Light] {
        group(id)?.lightIDs.compactMap { lightsByID[$0] } ?? []
    }

    func groups(containing id: LightID) -> [LightGroup] {
        groups.filter { $0.lightIDs.contains(id) }
    }

    /// Lookup by name for intents/Siri (case- and diacritic-insensitive).
    func group(named name: String) -> LightGroup? {
        groups.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

// MARK: - Editing

extension AppModel {
    @discardableResult
    func addGroup(named name: String, lightIDs: [LightID] = [], transitionMilliseconds: Int? = nil) -> LightGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = LightGroup(
            name: trimmed.isEmpty ? "Group" : trimmed,
            lightIDs: Self.unique(lightIDs),
            transitionMilliseconds: transitionMilliseconds
        )
        groups.append(group)
        scheduleLibrarySave()
        return group
    }

    func renameGroup(_ id: LightGroup.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        scheduleLibrarySave()
    }

    /// Replaces a group's members. Turns Light Sync off if the new members would make two
    /// groups mirror each other.
    func setLights(_ lightIDs: [LightID], forGroup id: LightGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].lightIDs = Self.unique(lightIDs)
        if let source = groups[index].syncSourceID, syncWouldLoop(source: source, group: groups[index]) {
            groups[index].syncSourceID = nil
            showToast("Light Sync for \(groups[index].name) was turned off: it would mirror lights back and forth.", isError: true)
        }
        lastMirroredCommand[id] = nil
        scheduleLibrarySave()
    }

    func setMember(_ lightID: LightID, _ isMember: Bool, inGroup id: LightGroup.ID) {
        guard let group = group(id) else { return }
        var members = group.lightIDs.filter { $0 != lightID }
        if isMember { members.append(lightID) }
        setLights(members, forGroup: id)
    }

    /// Transition for every command sent to the group (nil = provider default).
    func setTransition(milliseconds: Int?, forGroup id: LightGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].transitionMilliseconds = milliseconds.map { max(0, $0) }
        scheduleLibrarySave()
    }

    func deleteGroup(_ id: LightGroup.ID) {
        groups.removeAll { $0.id == id }
        lastMirroredCommand[id] = nil
        scheduleLibrarySave()
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        scheduleLibrarySave()
    }

    private static func unique(_ ids: [LightID]) -> [LightID] {
        var seen: Set<LightID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Control

extension AppModel {
    /// Sends one command to every member, with the group's transition unless the command sets
    /// its own. Optimistic per light; one coalesced group send (latest wins while dragging).
    func send(_ command: LightCommand, toGroup id: LightGroup.ID) {
        guard let group = group(id) else { return }
        send(Self.command(command, for: group), toLights: group.lightIDs, groupKey: .lightGroup(id))
    }

    /// `command` with the group's transition filled in (an explicit transition wins).
    static func command(_ command: LightCommand, for group: LightGroup) -> LightCommand {
        var command = command
        if command.transition == nil { command.transition = group.transition }
        return command
    }

    func setPower(_ isOn: Bool, forGroup id: LightGroup.ID) {
        send(LightCommand(on: isOn), toGroup: id)
    }

    func setBrightness(_ brightness: Double, forGroup id: LightGroup.ID) {
        send(LightCommand(on: true, brightness: brightness), toGroup: id)
    }

    /// Colour temperature for the whole group; each light clamps to its own range.
    func setKelvin(_ kelvin: Int, forGroup id: LightGroup.ID) {
        send(LightCommand(on: true, color: .kelvin(kelvin)), toGroup: id)
    }

    /// Colour for the whole group; each provider converts to what its lights support.
    func setColor(_ hs: HS, forGroup id: LightGroup.ID) {
        send(LightCommand(on: true, color: .hs(hs)), toGroup: id)
    }

    /// True if any member is on.
    func isAnyOn(inGroup id: LightGroup.ID) -> Bool {
        lights(inGroup: id).contains { $0.state.isOn }
    }

    /// Average brightness of the dimmable members that are on (1 if none).
    func averageBrightness(inGroup id: LightGroup.ID) -> Double {
        let on = lights(inGroup: id).filter { $0.capabilities.supportsBrightness && $0.state.isOn }
        guard !on.isEmpty else { return 1 }
        return on.map { $0.state.brightness ?? 1 }.reduce(0, +) / Double(on.count)
    }
}

// MARK: - Light Sync

extension AppModel {
    /// Starts mirroring `source` to the group's other members, or stops when nil. Refuses a
    /// source that would make groups mirror each other in a loop.
    @discardableResult
    func setSyncSource(_ source: LightID?, forGroup id: LightGroup.ID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        if let source, syncWouldLoop(source: source, group: groups[index]) {
            showToast("Can't sync from that light: groups would mirror each other in a loop.", isError: true)
            return false
        }
        groups[index].syncSourceID = source
        lastMirroredCommand[id] = nil
        scheduleLibrarySave()
        if let source { mirrorLightSync(from: source) }
        return true
    }

    /// Called whenever a light's state changes (optimistic command or provider report):
    /// pushes that state to every group syncing from it.
    func mirrorLightSync(from source: LightID) {
        guard let light = lightsByID[source] else { return }
        for group in groups where group.syncSourceID == source {
            let targets = group.syncTargets.filter { lightsByID[$0] != nil }
            guard !targets.isEmpty else { continue }
            let command = Self.mirrorCommand(for: light.state, transition: group.transition)
            guard lastMirroredCommand[group.id] != command else { continue }
            lastMirroredCommand[group.id] = command
            // A separate coalescing slot from the group controls, so neither replaces the
            // other's targets. Targets that are themselves sync sources propagate in turn;
            // `syncWouldLoop` guarantees the chain ends.
            send(command, toLights: targets, groupKey: .group("light-sync-\(group.id.uuidString)"))
        }
    }

    /// The command that makes another light look like `state`. Effects are vendor-specific and
    /// are not mirrored; colour is converted per target by the providers.
    static func mirrorCommand(for state: LightState, transition: Duration?) -> LightCommand {
        var command = state.asCommand
        command.effect = nil
        command.transition = transition
        return command
    }

    /// True if syncing `group` from `source` would let a light's change come back to itself
    /// through Light Sync groups (A mirrors to B, B mirrors to A).
    func syncWouldLoop(source: LightID, group: LightGroup) -> Bool {
        var edges: [LightID: Set<LightID>] = [:]
        for other in groups where other.id != group.id {
            if let s = other.syncSourceID { edges[s, default: []].formUnion(other.syncTargets) }
        }
        var candidate = group
        candidate.syncSourceID = source
        edges[source, default: []].formUnion(candidate.syncTargets)

        // Depth-first search from the source's targets back to the source.
        var stack = Array(edges[source] ?? [])
        var visited: Set<LightID> = []
        while let next = stack.popLast() {
            if next == source { return true }
            guard visited.insert(next).inserted else { continue }
            stack.append(contentsOf: edges[next] ?? [])
        }
        return false
    }
}
