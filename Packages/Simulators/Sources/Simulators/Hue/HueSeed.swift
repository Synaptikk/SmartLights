// Seed data for FakeHueBridge: 3 lights (colour, white ambiance, white), 2 rooms, 1 zone, 2 scenes.
// Resource shapes follow CLIP v2 GET responses (openhue-api spec / aiohue models).

import Foundation

extension FakeHueBridge {
    /// Stable ids of the seeded resources so tests can address them directly.
    public enum SeedID {
        public static let bridgeDevice = "00000000-0000-4000-8000-000000000d00"
        public static let colorDevice = "00000000-0000-4000-8000-000000000d01"
        public static let ambianceDevice = "00000000-0000-4000-8000-000000000d02"
        public static let whiteDevice = "00000000-0000-4000-8000-000000000d03"

        public static let colorLight = "00000000-0000-4000-8000-000000000101"
        public static let ambianceLight = "00000000-0000-4000-8000-000000000102"
        public static let whiteLight = "00000000-0000-4000-8000-000000000103"

        public static let livingRoom = "00000000-0000-4000-8000-000000000201"
        public static let hallway = "00000000-0000-4000-8000-000000000202"
        public static let readingZone = "00000000-0000-4000-8000-000000000301"

        public static let livingRoomGroup = "00000000-0000-4000-8000-000000000401"
        public static let hallwayGroup = "00000000-0000-4000-8000-000000000402"
        public static let readingZoneGroup = "00000000-0000-4000-8000-000000000403"

        public static let relaxScene = "00000000-0000-4000-8000-000000000501"
        public static let nightlightScene = "00000000-0000-4000-8000-000000000502"

        public static let bridge = "00000000-0000-4000-8000-000000000601"
    }

    static func ref(_ rid: String, _ rtype: String) -> JSON { ["rid": .string(rid), "rtype": .string(rtype)] }

    static func seedResources(bridgeId: String) -> [String: [JSONObject]] {
        typealias S = SeedID
        let gamutC: JSON = [
            "red": ["x": 0.6915, "y": 0.3083], "green": ["x": 0.17, "y": 0.7], "blue": ["x": 0.1532, "y": 0.0475],
        ]
        func device(_ id: String, model: String, product: String, archetype: String, name: String, services: [JSON])
            -> JSONObject
        {
            [
                "id": .string(id),
                "product_data": [
                    "model_id": .string(model), "manufacturer_name": "Signify Netherlands B.V.",
                    "product_name": .string(product), "product_archetype": .string(archetype), "certified": true,
                    "software_version": "1.122.2",
                ],
                "metadata": ["name": .string(name), "archetype": .string(archetype)],
                "services": .array(services),
                "type": "device",
            ]
        }
        let devices: [JSONObject] = [
            device(
                S.bridgeDevice, model: "BSB002", product: "Hue Bridge", archetype: "bridge_v2", name: "Hue Bridge",
                services: [ref(S.bridge, "bridge")]),
            device(
                S.colorDevice, model: "LCA001", product: "Hue color lamp", archetype: "sultan_bulb", name: "Living lamp",
                services: [ref(S.colorLight, "light")]),
            device(
                S.ambianceDevice, model: "LTA001", product: "Hue white ambiance lamp", archetype: "sultan_bulb",
                name: "Desk lamp", services: [ref(S.ambianceLight, "light")]),
            device(
                S.whiteDevice, model: "LWA001", product: "Hue white lamp", archetype: "classic_bulb",
                name: "Hall bulb", services: [ref(S.whiteLight, "light")]),
        ]

        let colorLight: JSONObject = [
            "id": .string(S.colorLight), "id_v1": "/lights/1", "owner": ref(S.colorDevice, "device"),
            "metadata": ["name": "Living lamp", "archetype": "sultan_bulb", "function": "mixed"],
            "on": ["on": true],
            "dimming": ["brightness": 80.0, "min_dim_level": 0.2],
            "dimming_delta": [:],
            "color_temperature": [
                "mirek": nil, "mirek_valid": false, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 500],
            ],
            "color_temperature_delta": [:],
            "color": ["xy": ["x": 0.4573, "y": 0.41], "gamut": gamutC, "gamut_type": "C"],
            "dynamics": ["status": "none", "status_values": ["none", "dynamic_palette"], "speed": 0.0, "speed_valid": false],
            "alert": ["action_values": ["breathe"]],
            "mode": "normal",
            "type": "light",
        ]
        let ambianceLight: JSONObject = [
            "id": .string(S.ambianceLight), "id_v1": "/lights/2", "owner": ref(S.ambianceDevice, "device"),
            "metadata": ["name": "Desk lamp", "archetype": "sultan_bulb", "function": "functional"],
            "on": ["on": false],
            "dimming": ["brightness": 100.0, "min_dim_level": 0.5],
            "dimming_delta": [:],
            "color_temperature": [
                "mirek": 366, "mirek_valid": true, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 454],
            ],
            "color_temperature_delta": [:],
            "dynamics": ["status": "none", "status_values": ["none"], "speed": 0.0, "speed_valid": false],
            "alert": ["action_values": ["breathe"]],
            "mode": "normal",
            "type": "light",
        ]
        let whiteLight: JSONObject = [
            "id": .string(S.whiteLight), "id_v1": "/lights/3", "owner": ref(S.whiteDevice, "device"),
            "metadata": ["name": "Hall bulb", "archetype": "classic_bulb", "function": "functional"],
            "on": ["on": true],
            "dimming": ["brightness": 50.0, "min_dim_level": 1.0],
            "dimming_delta": [:],
            "dynamics": ["status": "none", "status_values": ["none"], "speed": 0.0, "speed_valid": false],
            "alert": ["action_values": ["breathe"]],
            "mode": "normal",
            "type": "light",
        ]

        func room(_ id: String, v1: String, name: String, archetype: String, children: [JSON], group: String, type: String)
            -> JSONObject
        {
            [
                "id": .string(id), "id_v1": .string(v1), "children": .array(children),
                "services": [ref(group, "grouped_light")],
                "metadata": ["name": .string(name), "archetype": .string(archetype)], "type": .string(type),
            ]
        }
        let rooms: [JSONObject] = [
            room(
                S.livingRoom, v1: "/groups/1", name: "Living room", archetype: "living_room",
                children: [ref(S.colorDevice, "device"), ref(S.ambianceDevice, "device")], group: S.livingRoomGroup,
                type: "room"),
            room(
                S.hallway, v1: "/groups/2", name: "Hallway", archetype: "hallway",
                children: [ref(S.whiteDevice, "device")], group: S.hallwayGroup, type: "room"),
        ]
        let zones: [JSONObject] = [
            room(
                S.readingZone, v1: "/groups/3", name: "Reading", archetype: "reading",
                children: [ref(S.colorLight, "light"), ref(S.whiteLight, "light")], group: S.readingZoneGroup,
                type: "zone")
        ]
        func group(_ id: String, v1: String, owner: JSON) -> JSONObject {
            [
                "id": .string(id), "id_v1": .string(v1), "owner": owner, "on": ["on": false],
                "dimming": ["brightness": 0.0], "dimming_delta": [:], "color_temperature": [:],
                "color_temperature_delta": [:], "color": [:], "alert": ["action_values": ["breathe"]],
                "signaling": ["signal_values": ["no_signal", "on_off"]], "dynamics": [:], "type": "grouped_light",
            ]
        }
        let groups: [JSONObject] = [
            group(S.livingRoomGroup, v1: "/groups/1", owner: ref(S.livingRoom, "room")),
            group(S.hallwayGroup, v1: "/groups/2", owner: ref(S.hallway, "room")),
            group(S.readingZoneGroup, v1: "/groups/3", owner: ref(S.readingZone, "zone")),
        ]
        func action(_ light: String, _ a: JSON) -> JSON { ["target": ref(light, "light"), "action": a] }
        let scenes: [JSONObject] = [
            [
                "id": .string(S.relaxScene), "id_v1": "/scenes/AbCdEfGh1234567",
                "actions": [
                    action(S.colorLight, ["on": ["on": true], "dimming": ["brightness": 56.3], "color_temperature": ["mirek": 447]]),
                    action(S.ambianceLight, ["on": ["on": true], "dimming": ["brightness": 56.3], "color_temperature": ["mirek": 447]]),
                ],
                "palette": ["color": [], "dimming": [], "color_temperature": [], "effects": []],
                "recall": [:],
                "metadata": ["name": "Relax", "image": ["rid": "a1f7da49-d181-4328-abea-68c9dc4b5416", "rtype": "public_image"]],
                "group": ref(S.livingRoom, "room"),
                "speed": 0.6031746031746031,
                "auto_dynamic": false,
                "status": ["active": "inactive"],
                "type": "scene",
            ],
            [
                "id": .string(S.nightlightScene), "id_v1": "/scenes/HiJkLmNo7654321",
                "actions": [
                    action(S.whiteLight, ["on": ["on": true], "dimming": ["brightness": 1.0]])
                ],
                "palette": ["color": [], "dimming": [], "color_temperature": [], "effects": []],
                "recall": [:],
                "metadata": ["name": "Nightlight"],
                "group": ref(S.hallway, "room"),
                "speed": 0.5,
                "auto_dynamic": false,
                "status": ["active": "inactive"],
                "type": "scene",
            ],
        ]
        let bridge: JSONObject = [
            "id": .string(S.bridge), "id_v1": "", "owner": ref(S.bridgeDevice, "device"),
            "bridge_id": .string(bridgeId.lowercased()), "time_zone": ["time_zone": "Europe/Amsterdam"], "type": "bridge",
        ]
        return [
            "device": devices,
            "light": [colorLight, ambianceLight, whiteLight],
            "room": rooms,
            "zone": zones,
            "grouped_light": groups,
            "scene": scenes,
            "bridge": [bridge],
        ]
    }
}
