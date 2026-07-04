import Foundation

/// Abstraction over "send an HTTP request, get bytes back" so SyncService is
/// testable without a real network (see SyncServiceTests: a FakeHTTPClient
/// records requests and returns canned responses).
protocol SyncHTTPClient {
    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int, headers: [String: String])
}

struct URLSessionHTTPClient: SyncHTTPClient {
    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int, headers: [String: String]) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        return (data, http.statusCode, headers)
    }
}

enum SyncError: LocalizedError {
    case invalidResponse
    case malformedBody
    case server(Int, String)
    case notEnabled

    var errorDescription: String? {
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
actor SyncService {
    struct Credentials: Codable { var accountId: String; var token: String; var seq: Double }

    private let baseURL: URL
    private let client: SyncHTTPClient
    private let defaults: UserDefaults
    private let credentialsKey = "artistos.sync.credentials"
    private(set) var credentials: Credentials?

    init(baseURL: URL = URL(string: "https://artist-os-sync.YOUR-SUBDOMAIN.workers.dev")!,
         client: SyncHTTPClient = URLSessionHTTPClient(),
         defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.client = client
        self.defaults = defaults
        if let data = defaults.data(forKey: credentialsKey),
           let creds = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = creds
        }
    }

    var isEnabled: Bool { credentials != nil }
    var currentSeq: Double { credentials?.seq ?? 0 }
    var accountID: String? { credentials?.accountId }

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
    func enableSync() async throws -> Credentials {
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

    func linkStart() async throws -> (code: String, expiresInSeconds: Int) {
        guard isEnabled else { throw SyncError.notEnabled }
        let (data, status, _) = try await client.send(request("/v1/link/start", method: "POST"))
        guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
        let body = try jsonObject(from: data)
        guard let code = body["code"] as? String else { throw SyncError.malformedBody }
        return (code, (body["expiresInSeconds"] as? NSNumber)?.intValue ?? 300)
    }

    @discardableResult
    func linkClaim(code: String) async throws -> Credentials {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let (data, status, _) = try await client.send(
            request("/v1/link/claim", method: "POST", jsonBody: ["code": trimmed])
        )
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

    func disableAndDeleteAccount() async throws {
        guard isEnabled else { return }
        _ = try? await client.send(request("/v1/account", method: "DELETE"))
        credentials = nil
        defaults.removeObject(forKey: credentialsKey)
    }

    // MARK: - Push / pull

    func push(changes: [SyncLogic.JSONDict]) async throws -> (applied: Int, skipped: Int) {
        guard isEnabled else { throw SyncError.notEnabled }
        var applied = 0, skipped = 0
        for batch in stride(from: 0, to: changes.count, by: 200) {
            let slice = Array(changes[batch..<min(batch + 200, changes.count)])
            let (data, status, _) = try await client.send(
                request("/v1/sync/push", method: "POST", jsonBody: ["changes": slice])
            )
            guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
            let body = try jsonObject(from: data)
            applied += (body["applied"] as? NSNumber)?.intValue ?? 0
            skipped += (body["skipped"] as? NSNumber)?.intValue ?? 0
        }
        return (applied, skipped)
    }

    /// Pulls all pages of remote changes since the last cursor and returns
    /// them flattened, advancing and persisting the cursor after each page
    /// so a mid-pagination network failure doesn't lose already-fetched
    /// progress. Returns a plain array (not a callback) specifically so
    /// applying changes never has to cross back into the caller's actor
    /// isolation from inside this actor's execution.
    func pullAll() async throws -> [SyncLogic.JSONDict] {
        guard isEnabled else { throw SyncError.notEnabled }
        var all: [SyncLogic.JSONDict] = []
        var hasMore = true
        while hasMore {
            let (data, status, _) = try await client.send(
                request("/v1/sync/pull?since=\(currentSeq)", method: "GET")
            )
            guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
            let body = try jsonObject(from: data)
            for case let change as SyncLogic.JSONDict in (body["changes"] as? [Any] ?? []) {
                all.append(change)
            }
            if let seq = (body["seq"] as? NSNumber)?.doubleValue { setSeq(seq) }
            hasMore = (body["hasMore"] as? Bool) ?? false
        }
        return all
    }

    // MARK: - Opt-in audio blobs ("Make available everywhere")

    func uploadBlob(assetID: String, data: Data, contentType: String) async throws {
        guard isEnabled else { throw SyncError.notEnabled }
        let (body, status, _) = try await client.send(
            request("/v1/blob/\(assetID)", method: "PUT", rawBody: data, contentType: contentType)
        )
        guard status == 200 else { throw SyncError.server(status, errorMessage(from: body)) }
    }

    func downloadBlob(assetID: String) async throws -> Data {
        guard isEnabled else { throw SyncError.notEnabled }
        let (data, status, _) = try await client.send(request("/v1/blob/\(assetID)", method: "GET"))
        guard status == 200 else { throw SyncError.server(status, errorMessage(from: data)) }
        return data
    }
}
