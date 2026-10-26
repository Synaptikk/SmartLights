#if canImport(Darwin)
import Foundation

/// Small JSON-over-HTTP helper: base URL + default headers, status mapping to ``HTTPError``,
/// `Decodable` responses. Use a session from ``TrustingSessionDelegate`` for devices with private CAs.
public struct HTTPClient: Sendable {
    public let baseURL: URL
    public let session: URLSession
    /// Sent with every request (e.g. `hue-application-key`). Never logged.
    public let defaultHeaders: [String: String]
    public let timeout: Duration

    public init(baseURL: URL, session: URLSession = .shared, defaultHeaders: [String: String] = [:],
                timeout: Duration = .seconds(10)) {
        self.baseURL = baseURL
        self.session = session
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
    }

    /// Builds a request for `path` (relative to `baseURL`) with query items and headers.
    public func makeRequest(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [],
                            body: Data? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        var url = path.isEmpty ? baseURL : baseURL.appending(path: path)
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw HTTPError.invalidURL(path)
            }
            components.queryItems = (components.queryItems ?? []) + query
            guard let withQuery = components.url else { throw HTTPError.invalidURL(path) }
            url = withQuery
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout.timeInterval
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in defaultHeaders { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Performs a request and returns the raw body; non-2xx statuses throw ``HTTPError``.
    @discardableResult
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        if let error = HTTPError.check(status: http.statusCode, body: data,
                                       retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
            throw error
        }
        return (data, http)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    @discardableResult
    public func send(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await send(makeRequest(method, path: path, query: query, body: body, headers: headers))
    }

    /// GET and decode JSON.
    public func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: Response.Type,
                                         decoder: JSONDecoder = JSONDecoder()) async throws -> Response {
        let (data, _) = try await send(.get, path: path, query: query)
        return try Self.decode(type, from: data, decoder: decoder)
    }

    /// Sends a JSON body and decodes a JSON response.
    public func send<Body: Encodable, Response: Decodable>(
        _ method: HTTPMethod, path: String, json body: Body, as type: Response.Type,
        encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Response {
        let payload: Data
        do { payload = try encoder.encode(body) } catch { throw HTTPError.decoding("encode: \(error)") }
        let (data, _) = try await send(method, path: path, body: payload)
        return try Self.decode(type, from: data, decoder: decoder)
    }

    public static func decode<Response: Decodable>(_ type: Response.Type, from data: Data,
                                                   decoder: JSONDecoder = JSONDecoder()) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HTTPError.decoding(String(describing: error))
        }
    }
}
#endif
