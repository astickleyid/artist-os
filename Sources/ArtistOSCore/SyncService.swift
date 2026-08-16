import Foundation

/// Abstraction over "send an HTTP request, get bytes back" so SyncService is
/// testable without a real network (see SyncServiceTests: a FakeHTTPClient
/// records requests and returns canned responses).
public protocol SyncHTTPClient {
    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int, headers: [String: String])
}

public struct URLSessionHTTPClient: SyncHTTPClient {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int, headers: [String: String]) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        return (data, http.statusCode, headers)
    }
}

public enum SyncError: LocalizedError {
    case invalidResponse
    case malformedBody
    case server(Int, String)
    case notEnabled

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The sync server sent an unexpected response."
        case .malformedBody: return "The sync server response could not be parsed."
        case .server(let code, let message): return "Sync error (\(code)): \(message)"
        case .notEnabled: return "Sync is not enabled on this device."
        }
    }
}

/// Talks to the Artist OS sync Worker (worker/src/index.js). Metadata-first:
/// songs/assets/events sync automatically; audio only uploads when a person
/// explicitly opts an asset in ("Make available everywhere"), per VISION.md.
public actor SyncService {
    public struct Credentials: Codable {
        public var accountId: String; public var token: String; public var seq: Double
        public init(accountId: String, token: String, seq: Double) {
            self.accountId = accountId; self.token = token; self.seq = seq
        }
    }

    private let baseURL: URL
    private let client: SyncHTTPClient
    private let defaults: UserDefaults
    private let credentialsKey = "artistos.sync.credentials"
    private(set) var credentials: Credentials?

    /// Snapshot of whether this service already had credentials when it was created.
    /// App startup uses this instead of asking `isEnabled` from a delayed Task, which
    /// could otherwise race with a person enabling sync moments after launch and
    /// accidentally trigger a second pull.
    public nonisolated let wasEnabledAtInitialization: Bool

    public init(baseURL: URL = URL(string: "https://artist-os-sync.astickley9.workers.dev")!,
         client: SyncHTTPClient = URLSessionHTTPClient(),
         defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.client = client
        self.defaults = defaults
        let loadedCredentials: Credentials?
        if let data = defaults.data(forKey: credentialsKey),
           let creds = try? JSONDecoder().decode(Credentials.self, from: data) {
            loadedCredentials = creds
        } else {
            loadedCredentials = nil
        }
        self.credentials = loadedCredentials
        self.wasEnabledAtInitialization = loadedCredentials != nil
    }

    public var isEnabled: Bool { credentials != nil }
    public var currentSeq: Double { credentials?.seq ?? 0 }
    public var accountID: String? { credentials?.accountId }

    private func saveCredentials() {
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        defaults.set(data, forKey: credentialsKey)
    }

    private func setSeq(_ seq: Double) {
        credentials?.seq = seq
        saveCredentials()
    }

    private func request(_ path: String, method: String, jsonBody: Any? = nil, rawBody: Data? = nil,
                         contentType: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let token = credentials?.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        } else if let rawBody {
            req.httpBody = rawBody
            req.setValue(String(rawBody.count), forHTTPHeaderField: "content-length")
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "content-type") }
        }
        return req
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.malformedBody
        }
        return obj
    }

    private func errorMessage(from data: Data) -> String {
        (try? jsonObject(from: data))?["error"] as? String ?? "unknown error"
    }

    // MARK: - Account + device linking

    @discardableResult
    public func enableSync() async throws -> Credentials {
        if let credentials { return credentials }
        let (data, status, _) = try await client.send(request("/v1/account", method: "POST"))
        guard status == 201 else { throw SyncError.server(status, errorMessage(from: data)) }
        let body = try jsonObject(from: data)
        guard let accountId = body["accountId"] as? String, let token = body["token"] as? String else {
            throw SyncError.malformedBody
        }
        let creds = Credentials(accountId: accountId, token: token, seq: 0)
        credentials = creds
        saveCredentials()
        return creds
    }

    public func linkStart() async throws -> (code: String, expiresInSeconds: Int) {
        guard isEnabled else { throw SyncError.notEnabled }
        let (data, status, _) = try await client.send(request("/v1/link/start", method: "POST"))
        guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
        let body = try jsonObject(from: data)
        guard let code = body["code"] as? String,
              let expires = (body["expiresInSeconds"] as? NSNumber)?.intValue else { throw SyncError.malformedBody }
        return (code, expires)
    }

    @discardableResult
    public func linkClaim(code: String) async throws -> Credentials {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let (data, status, _) = try await client.send(request("/v1/link/claim", method: "POST", jsonBody: ["code": cleaned]))
        guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
        let body = try jsonObject(from: data)
        guard let accountId = body["accountId"] as? String, let token = body["token"] as? String else {
            throw SyncError.malformedBody
        }
        let creds = Credentials(accountId: accountId, token: token, seq: 0)
        credentials = creds
        saveCredentials()
        return creds
    }

    public func disableAndDeleteAccount() async throws {
        guard isEnabled else { return }
        let (data, status, _) = try await client.send(request("/v1/account", method: "DELETE"))
        guard (200..<300).contains(status) else { throw SyncError.server(status, errorMessage(from: data)) }
        credentials = nil
        defaults.removeObject(forKey: credentialsKey)
    }

    // MARK: - Metadata push / pull

    @discardableResult
    public func push(changes: [SyncLogic.JSONDict]) async throws -> Double {
        guard isEnabled else { throw SyncError.notEnabled }
        guard !changes.isEmpty else { return currentSeq }
        var latest = currentSeq
        for start in stride(from: 0, to: changes.count, by: 200) {
            let end = min(start + 200, changes.count)
            let batch = Array(changes[start..<end])
            let (data, status, _) = try await client.send(request("/v1/sync/push", method: "POST", jsonBody: ["changes": batch]))
            guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
            let body = try jsonObject(from: data)
            latest = max(latest, (body["seq"] as? NSNumber)?.doubleValue ?? latest)
        }
        setSeq(latest)
        return latest
    }

    public func pullAll() async throws -> [SyncLogic.JSONDict] {
        guard isEnabled else { throw SyncError.notEnabled }
        var all: [SyncLogic.JSONDict] = []
        var cursor = currentSeq
        while true {
            let (data, status, _) = try await client.send(request("/v1/sync/pull?since=\(cursor)", method: "GET"))
            guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
            let body = try jsonObject(from: data)
            let changes = body["changes"] as? [SyncLogic.JSONDict] ?? []
            all.append(contentsOf: changes)
            let next = (body["seq"] as? NSNumber)?.doubleValue ?? cursor
            let hasMore = (body["hasMore"] as? Bool) ?? false
            cursor = next
            if !hasMore { break }
        }
        setSeq(cursor)
        return all
    }

    // MARK: - Opt-in audio blobs

    public func uploadBlob(assetID: String, data: Data, contentType: String) async throws {
        guard isEnabled else { throw SyncError.notEnabled }
        let (response, status, _) = try await client.send(request("/v1/assets/\(assetID)/blob", method: "PUT", rawBody: data, contentType: contentType))
        guard (200..<300).contains(status) else { throw SyncError.server(status, errorMessage(from: response)) }
    }
}