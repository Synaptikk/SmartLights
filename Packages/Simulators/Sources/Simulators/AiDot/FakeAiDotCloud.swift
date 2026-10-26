// Fake AiDot cloud (`https://prod-{region}-api.arnoo.com/v35`), served over plain HTTP.
// Endpoints and fields follow python-aidot client.py / const.py.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

public final class FakeAiDotCloud: Simulator {
    public struct Configuration: Sendable {
        public var host: String = "127.0.0.1"
        public var port: Int = 0
        public var username: String = "user@example.com"
        public var userId: String = "1840000000000000001"
        public var houseId: String = "h-0001"
        public var houseName: String = "My Home"
        /// Also list a house shared with the user (`isOwner: false`) that clients must skip.
        public var includeSharedHouse: Bool = false
        /// `password` field values (RSA-base64 strings) that fail with 560080.
        public var badPasswords: Set<String> = []
        /// Usernames whose login always fails with 560080 ("wrong password" in tests,
        /// since the RSA ciphertext is randomised and cannot be predicted).
        public var badPasswordUsernames: Set<String> = ["wrong@example.com"]
        /// Require `Appid: 1383974540041977857`.
        public var requireAppId: Bool = true
        /// A new login invalidates earlier tokens (observed on the real service).
        public var singleSession: Bool = true

        public init() {}
        public init(host: String = "127.0.0.1", port: Int = 0, userId: String = "1840000000000000001") {
            self.host = host
            self.port = port
            self.userId = userId
        }
    }

    struct Tokens {
        var access: String
        var refresh: String
        var accessExpired = false
    }

    struct State {
        var config: Configuration
        var tokens: [Tokens] = []
        var refreshTokenInvalid = false
        var channel: (any Channel)?
        var port: Int?
        var loginCount = 0
        var requestLog: [String] = []
    }

    public let name: String
    public let group: any EventLoopGroup
    private let state: NIOLockedValueBox<State>
    private let devices: NIOLockedValueBox<[FakeAiDotDevice]>
    private let limits = NIOLockedValueBox(HTTPLimits())

    public init(
        _ config: Configuration = Configuration(), devices: [FakeAiDotDevice] = [], name: String = "aidot-cloud",
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.name = name
        self.group = group
        self.state = NIOLockedValueBox(State(config: config))
        self.devices = NIOLockedValueBox(devices)
    }

    public func start() async throws {
        let cfg = state.withLockedValue { $0.config }
        guard state.withLockedValue({ $0.channel }) == nil else { throw SimulatorError.alreadyStarted }
        let server = MiniHTTPServer(group: group, limits: limits) { [self] req in .response(self.handle(req)) }
        let ch = try await server.bind(host: cfg.host, port: cfg.port, tls: nil)
        state.withLockedValue {
            $0.channel = ch
            $0.port = ch.localAddress?.port
        }
    }

    public func stop() async throws {
        let ch = state.withLockedValue { s -> (any Channel)? in
            defer {
                s.channel = nil
                s.port = nil
            }
            return s.channel
        }
        try? await ch?.close()
    }

    public var boundPorts: [String: Int] {
        guard let p = port else { return [:] }
        return ["http": p]
    }

    public var port: Int? { state.withLockedValue { $0.port } }
    /// Base URL to give the provider, e.g. `http://127.0.0.1:54321/v35`.
    public var baseURL: String? {
        let (host, port) = state.withLockedValue { ($0.config.host, $0.port) }
        return port.map { "http://\(host == "0.0.0.0" ? "127.0.0.1" : host):\($0)/v35" }
    }

    // MARK: Test controls

    public func addDevice(_ d: FakeAiDotDevice) { devices.withLockedValue { $0.append(d) } }
    public var loginCount: Int { state.withLockedValue { $0.loginCount } }
    public var requestLog: [String] { state.withLockedValue { $0.requestLog } }
    public var currentAccessToken: String? { state.withLockedValue { $0.tokens.last?.access } }
    public var currentRefreshToken: String? { state.withLockedValue { $0.tokens.last?.refresh } }

    /// Next authenticated call with the current token answers 401 / 21026 (TOKEN_EXPIRED).
    public func expireAccessTokens() {
        state.withLockedValue { s in for i in s.tokens.indices { s.tokens[i].accessExpired = true } }
    }

    /// `POST /users/refreshToken` answers 400 / 21025 (LOGIN_INVALID) from now on.
    public func invalidateRefreshTokens(_ invalid: Bool = true) {
        state.withLockedValue { $0.refreshTokenInvalid = invalid }
    }

    // MARK: HTTP

    static func error(_ status: HTTPResponseStatus, code: Int, desc: String) -> HTTPResponse {
        .json(status, ["code": .int(code), "desc": .string(desc)])
    }

    static func token() -> String { SimCrypto.hexEncode(SimCrypto.randomBytes(16)) }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        let cfg = state.withLockedValue { s -> Configuration in
            s.requestLog.append("\(req.method.rawValue) \(req.uri)")
            return s.config
        }
        guard req.path.hasPrefix("/v35/") else { return Self.error(.notFound, code: 404, desc: "not found") }
        let path = String(req.path.dropFirst(4))
        if cfg.requireAppId, req.headers.first(name: "Appid") != AiDotConstants.appId {
            return Self.error(.badRequest, code: 20001, desc: "invalid appid")
        }

        switch (req.method, path) {
        case (.POST, "/users/loginWithFreeVerification"):
            return login(req, cfg)
        case (.POST, "/users/refreshToken"):
            return refresh(req)
        default:
            break
        }

        // Authenticated endpoints.
        let tok = req.headers.first(name: "Token") ?? ""
        let auth = state.withLockedValue { s -> Int? in
            guard let t = s.tokens.first(where: { $0.access == tok }) else { return AiDotConstants.loginInvalid }
            return t.accessExpired ? AiDotConstants.tokenExpired : nil
        }
        if let code = auth {
            return Self.error(
                .unauthorized, code: code, desc: code == AiDotConstants.tokenExpired ? "token expired" : "login invalid")
        }

        if req.method == .GET, path == "/houses" {
            var houses: [JSON] = [
                [
                    "id": .string(cfg.houseId), "name": .string(cfg.houseName), "isOwner": true, "isDefault": true,
                    "ownerId": .string(cfg.userId),
                ]
            ]
            if cfg.includeSharedHouse {
                houses.append(
                    ["id": "h-shared", "name": "Friend's Home", "isOwner": false, "isDefault": false, "ownerId": "1840000000000000999"])
            }
            return .json(.ok, .array(houses))
        }
        if req.method == .GET, path == "/devices" {
            let houseId = req.query["houseId"] ?? ""
            let list = devices.withLockedValue { $0 }.filter { $0.info.houseId == houseId }.map { JSON.object(record(for: $0)) }
            return .json(.ok, .array(list))
        }
        if req.method == .GET, path.hasPrefix("/products/") {
            let ids = path.dropFirst("/products/".count).split(separator: ",").map(String.init)
            let all = devices.withLockedValue { $0 }
            var seen = Set<String>()
            var out: [JSON] = []
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                if let d = all.first(where: { $0.info.productId == id }) { out.append(.object(product(for: d.info))) }
            }
            return .json(.ok, .array(out))
        }
        return Self.error(.notFound, code: 404, desc: "not found")
    }

    func login(_ req: HTTPRequest, _ cfg: Configuration) -> HTTPResponse {
        guard let body = req.json?.objectValue, let username = body["username"]?.stringValue,
            let password = body["password"]?.stringValue
        else { return Self.error(.badRequest, code: 10001, desc: "invalid params") }
        let decoded = Data(base64Encoded: password)
        if decoded == nil || decoded!.isEmpty || cfg.badPasswords.contains(password)
            || cfg.badPasswordUsernames.contains(username) || username.lowercased() != cfg.username.lowercased()
        {
            return Self.error(.badRequest, code: AiDotConstants.userPasswordIncorrect, desc: "username or password incorrect")
        }
        let t = Tokens(access: Self.token(), refresh: Self.token())
        state.withLockedValue { s in
            if s.config.singleSession { s.tokens = [] }
            s.tokens.append(t)
            s.loginCount += 1
            s.refreshTokenInvalid = false
        }
        return .json(
            .ok,
            [
                "id": .string(cfg.userId), "username": .string(username), "nickName": "Sim User",
                "accessToken": .string(t.access), "refreshToken": .string(t.refresh), "expiresIn": 2_592_000,
                "terminalId": body["terminalId"] ?? "", "countryKey": body["countryKey"] ?? "", "region": "us",
            ])
    }

    func refresh(_ req: HTTPRequest) -> HTTPResponse {
        let rt = req.json?["refreshToken"]?.stringValue ?? ""
        let new = state.withLockedValue { s -> Tokens? in
            guard !s.refreshTokenInvalid, let i = s.tokens.firstIndex(where: { $0.refresh == rt }) else { return nil }
            let t = Tokens(access: Self.token(), refresh: Self.token())
            s.tokens[i] = t
            return t
        }
        guard let new else { return Self.error(.badRequest, code: AiDotConstants.loginInvalid, desc: "login invalid") }
        return .json(.ok, ["accessToken": .string(new.access), "refreshToken": .string(new.refresh), "expiresIn": 2_592_000])
    }

    func record(for d: FakeAiDotDevice) -> JSONObject {
        let info = d.info
        let st = d.lightState
        var props = JSONObject()
        props["ssidName"] = "HomeWiFi"
        props["ipAddress"] = .string(d.advertisedIP)
        props["macAddress"] = .string(info.mac)
        for m in st.attr.members { props[m.key] = m.value }
        return [
            "id": .string(info.id), "name": .string(info.name), "mac": .string(info.mac), "type": "light",
            "modelId": .string(info.modelId), "productId": .string(info.productId), "houseId": .string(info.houseId),
            "roomId": .string(info.roomId), "online": true, "firmwareVersion": .string(info.firmwareVersion),
            "hardwareVersion": .string(info.hardwareVersion), "protocolVersion": "2.0.0",
            "aesKey": [.string(info.aesKey)], "password": .string(info.password), "properties": .object(props),
        ]
    }

    func product(for info: AiDotDeviceInfo) -> JSONObject {
        var modules: [JSON] = [
            ["identity": "control.light.onoff", "properties": [["identifier": "OnOff"]]],
            ["identity": "control.light.dimming", "properties": [["identifier": "Dimming", "minValue": 0, "maxValue": 100]]],
        ]
        if let r = info.cctRange {
            modules.append(
                [
                    "identity": "control.light.cct",
                    "properties": [["identifier": "CCT", "minValue": .int(r.lowerBound), "maxValue": .int(r.upperBound)]],
                ])
        }
        if info.supportsRGBW {
            modules.append(["identity": "control.light.rgbw", "properties": [["identifier": "RGBW"]]])
        }
        return [
            "id": .string(info.productId), "name": "Smart Wi-Fi Bulb", "modelId": .string(info.modelId),
            "type": "light", "serviceModules": .array(modules),
        ]
    }
}
