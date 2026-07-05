import XCTest
import ArtistOSCore
@testable import ArtistOS

/// Records every request it receives and returns pre-scripted responses in
/// order. Lets SyncService be tested exactly like the web client was tested
/// against the real worker module — here, against a faithful stand-in for
/// its HTTP surface, with zero real networking.
actor FakeHTTPClient: SyncHTTPClient {
    struct Recorded { let request: URLRequest }
    struct Scripted { let data: Data; let statusCode: Int; let headers: [String: String]
        init(json: Any, status: Int = 200, headers: [String: String] = [:]) {
            data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            statusCode = status; self.headers = headers
        }
        init(data: Data, status: Int = 200) { self.data = data; statusCode = status; headers = [:] }
    }

    private(set) var recorded: [Recorded] = []
    private var script: [Scripted]

    init(script: [Scripted]) { self.script = script }

    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int, headers: [String: String]) {
        recorded.append(Recorded(request: request))
        guard !script.isEmpty else { throw SyncError.invalidResponse }
        let next = script.removeFirst()
        return (next.data, next.statusCode, next.headers)
    }

    func lastBodyJSON() -> [String: Any]? {
        guard let body = recorded.last?.request.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

final class SyncServiceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "artistos-synctest-\(UUID().uuidString)")!
    }

    func testEnableSyncStoresCredentialsAndIsIdempotent() async throws {
        let fake = FakeHTTPClient(script: [.init(json: ["accountId": "acc1", "token": "tok1"], status: 201)])
        let service = SyncService(client: fake, defaults: freshDefaults())
        let creds = try await service.enableSync()
        XCTAssertEqual(creds.accountId, "acc1")
        let isEnabled = await service.isEnabled
        XCTAssertTrue(isEnabled)

        // second call must NOT hit the network again (already enabled)
        _ = try await service.enableSync()
        let count = await fake.recorded.count
        XCTAssertEqual(count, 1, "enableSync should be idempotent once credentials exist")
    }

    func testEnableSyncSurfacesServerError() async throws {
        let fake = FakeHTTPClient(script: [.init(json: ["error": "boom"], status: 500)])
        let service = SyncService(client: fake, defaults: freshDefaults())
        do {
            _ = try await service.enableSync()
            XCTFail("expected an error")
        } catch let error as SyncError {
            guard case .server(let code, let message) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "boom")
        }
    }

    func testAuthorizationHeaderAttachedAfterEnabling() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "sekret"], status: 201),
            .init(json: ["applied": 1, "skipped": 0, "seq": 1])
        ])
        let service = SyncService(client: fake, defaults: freshDefaults())
        _ = try await service.enableSync()
        _ = try await service.push(changes: [["kind": "song", "id": "s1", "updatedAt": 1.0, "data": [:]]])
        let secondRequest = await fake.recorded[1].request
        XCTAssertEqual(secondRequest.value(forHTTPHeaderField: "authorization"), "Bearer sekret")
    }

    func testPushBatchesLargeChangeSetsAt200() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "a", "token": "t"], status: 201),
            .init(json: ["applied": 200, "skipped": 0, "seq": 200]),
            .init(json: ["applied": 50, "skipped": 0, "seq": 250])
        ])
        let service = SyncService(client: fake, defaults: freshDefaults())
        _ = try await service.enableSync()
        let changes: [SyncLogic.JSONDict] = (0..<250).map { i in
            ["kind": "event", "id": "e\(i)", "updatedAt": Double(i)]
        }
        let result = try await service.push(changes: changes)
        XCTAssertEqual(result.applied, 250)
        let bodies: [Int] = await fake.recorded.dropFirst().map { rec in
            guard let httpBody = rec.request.httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let batchChanges = obj["changes"] as? [Any]
            else { return 0 }
            return batchChanges.count
        }
        XCTAssertEqual(bodies, [200, 50], "250 changes should split into batches of 200 then 50")
    }

    func testPullAllPaginatesAndAdvancesCursor() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "a", "token": "t"], status: 201),
            .init(json: ["changes": [["kind": "song", "id": "s1", "updatedAt": 1.0, "data": ["title": "A"]]],
                         "seq": 1, "hasMore": true]),
            .init(json: ["changes": [["kind": "song", "id": "s2", "updatedAt": 2.0, "data": ["title": "B"]]],
                         "seq": 2, "hasMore": false])
        ])
        let service = SyncService(client: fake, defaults: freshDefaults())
        _ = try await service.enableSync()
        let changes = try await service.pullAll()
        XCTAssertEqual(changes.map { $0["id"] as? String ?? "?" }, ["s1", "s2"])
        let finalSeq = await service.currentSeq
        XCTAssertEqual(finalSeq, 2)

        // second URL requested must carry the advanced cursor
        let urls = await fake.recorded.map { $0.request.url?.absoluteString ?? "" }
        XCTAssertTrue(urls[2].contains("since=1"), "pagination must request from the cursor left by page 1: \(urls[2])")
    }

    func testLinkStartRequiresSyncAlreadyEnabled() async throws {
        let fake = FakeHTTPClient(script: [])
        let service = SyncService(client: fake, defaults: freshDefaults())
        do {
            _ = try await service.linkStart()
            XCTFail("expected notEnabled error")
        } catch let error as SyncError {
            guard case .notEnabled = error else { return XCTFail("wrong case") }
        }
    }

    func testLinkClaimUppercasesAndTrimsCode() async throws {
        let fake = FakeHTTPClient(script: [.init(json: ["accountId": "a", "token": "t"])])
        let service = SyncService(client: fake, defaults: freshDefaults())
        _ = try await service.linkClaim(code: "  nsrem4  ")
        let body = await fake.lastBodyJSON()
        XCTAssertEqual(body?["code"] as? String, "NSREM4")
    }

    func testUploadBlobSetsContentLengthAndType() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "a", "token": "t"], status: 201),
            .init(json: ["ok": true, "size": 4])
        ])
        let service = SyncService(client: fake, defaults: freshDefaults())
        _ = try await service.enableSync()
        try await service.uploadBlob(assetID: "asset1", data: Data("wav!".utf8), contentType: "audio/wav")
        let req = await fake.recorded[1].request
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "audio/wav")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-length"), "4")
        XCTAssertTrue(req.url?.path.hasSuffix("/v1/blob/asset1") ?? false)
    }

    func testDisableAndDeleteAccountClearsLocalCredentials() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "a", "token": "t"], status: 201),
            .init(json: ["ok": true])
        ])
        let defaults = freshDefaults()
        let service = SyncService(client: fake, defaults: defaults)
        _ = try await service.enableSync()
        try await service.disableAndDeleteAccount()
        let isEnabled = await service.isEnabled
        XCTAssertFalse(isEnabled)
    }

    func testCredentialsPersistAcrossInstancesViaSharedDefaults() async throws {
        let defaults = freshDefaults()
        let fake1 = FakeHTTPClient(script: [.init(json: ["accountId": "acc1", "token": "tok1"], status: 201)])
        let service1 = SyncService(client: fake1, defaults: defaults)
        _ = try await service1.enableSync()

        // A brand-new SyncService instance backed by the same UserDefaults
        // (simulating an app relaunch) should pick the credentials back up.
        let fake2 = FakeHTTPClient(script: [])
        let service2 = SyncService(client: fake2, defaults: defaults)
        let isEnabled = await service2.isEnabled
        XCTAssertTrue(isEnabled)
        let accountID = await service2.accountID
        XCTAssertEqual(accountID, "acc1")
    }
}
