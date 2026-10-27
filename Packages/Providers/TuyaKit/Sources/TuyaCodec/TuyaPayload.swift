import Foundation

/// What the client asks a device to do.
public enum TuyaRequest: Sendable, Equatable {
    /// Set data points (`CONTROL`, or `CONTROL_NEW` on 3.4/3.5).
    case control([String: TuyaJSON])
    /// Read all data points (`DP_QUERY`; `DP_QUERY_NEW` on 3.4/3.5; `CONTROL_NEW` for device22).
    case dpQuery
    case heartbeat
    /// Ask the device to refresh (and push) the listed dps (`UPDATEDPS`).
    case updateDps([Int])
}

/// Port of tinytuya `XenonDevice.generate_payload` and its `payload_dict` (default, device22, v3.4, v3.5).
public enum TuyaPayload {
    /// Command code and JSON body. `time` is Unix seconds (`int(time.time())`).
    /// `dpsToRequest` is the device22 query list (tinytuya `dps_to_request`, values `null`).
    public static func build(_ request: TuyaRequest, version: TuyaVersion, deviceType: TuyaDeviceType = .default,
                             deviceId: String, time: Int, dpsToRequest: [String] = ["1"]) -> (command: TuyaCommand, json: TuyaJSON) {
        let modern = version.negotiatesSessionKey
        let id = TuyaJSON.string(deviceId)
        let stringTime = TuyaJSON.string(String(time))
        switch request {
        case .control(let dps):
            let ordered = orderedDPS(dps)
            if modern {
                return (.controlNew, ["protocol": 5, "t": .int(time), "data": ["dps": ordered]])
            }
            return (.control, ["devId": id, "uid": id, "t": stringTime, "dps": ordered])
        case .dpQuery:
            if deviceType == .device22 {
                let wanted = TuyaJSON.object(sortedKeys(dpsToRequest).map { ($0, .null) })
                return (.controlNew, ["devId": id, "uid": id, "t": stringTime, "dps": wanted])
            }
            if modern { return (.dpQueryNew, .object([])) }
            return (.dpQuery, ["gwId": id, "devId": id, "uid": id, "t": stringTime])
        case .heartbeat:
            return (.heartBeat, ["gwId": id, "devId": id])
        case .updateDps(let ids):
            return (.updateDps, ["dpId": .array(ids.map { .int($0) })])
        }
    }

    /// Python dicts keep insertion order; callers pass a Swift dictionary, so sort numerically for a
    /// stable, readable order.
    static func orderedDPS(_ dps: [String: TuyaJSON]) -> TuyaJSON {
        .object(sortedKeys(Array(dps.keys)).map { ($0, dps[$0]!) })
    }

    static func sortedKeys(_ keys: [String]) -> [String] {
        keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
    }
}

/// A decoded frame.
public struct TuyaResponse: Sendable, Equatable {
    public var seqno: UInt32
    public var command: UInt32
    public var retcode: UInt32?
    /// Decrypted payload bytes with the version header removed (empty for acks).
    public var plaintext: [UInt8]
    /// Parsed JSON body, if any.
    public var json: TuyaJSON?
    /// `dps` (or `data.dps` for 3.4+ pushes).
    public var dps: [String: TuyaJSON]?
    /// The device answered "json obj data unvalid": it is a device22 type (tinytuya switches dev_type).
    public var isDataUnvalid: Bool

    public var tuyaCommand: TuyaCommand? { TuyaCommand(rawValue: command) }
}
