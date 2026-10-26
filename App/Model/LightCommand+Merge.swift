import LightCore

extension LightCommand {
    /// Combines a queued command with a newer one (latest wins per field).
    /// A newer colour cancels a queued effect and vice versa, mirroring `LightState.applying`.
    func merging(_ newer: LightCommand) -> LightCommand {
        var out = self
        if let on = newer.on { out.on = on }
        if let brightness = newer.brightness { out.brightness = brightness }
        if let color = newer.color {
            out.color = color
            out.effect = nil
        }
        if let effect = newer.effect {
            out.effect = effect
            if newer.color == nil { out.color = nil }
        }
        if let transition = newer.transition { out.transition = transition }
        return out
    }
}
