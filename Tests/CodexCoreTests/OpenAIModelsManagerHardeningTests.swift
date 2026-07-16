import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import CodexCore

final class OpenAIModelsManagerHardeningTests: XCTestCase {
    override func tearDown() {
        CatalogURLProtocol.handler = nil
        super.tearDown()
    }

    func testRefreshUsesConditionalETagAndAcceptsNotModified() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let requestCount = CatalogLocked(0)
        CatalogURLProtocol.handler = { request in
            let count = requestCount.withValue { value in
                value += 1
                return value
            }
            switch count {
            case 1:
                XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                return CatalogURLProtocol.response(
                    for: request,
                    headers: ["ETag": "\"catalog-v1\""],
                    json: Self.catalogJSON(model: "gpt-cached")
                )
            case 2:
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"catalog-v1\"")
                return CatalogURLProtocol.response(
                    for: request,
                    statusCode: 304,
                    headers: ["ETag": "\"catalog-v1\""],
                    body: ""
                )
            default:
                XCTFail("Unexpected request \(count)")
                return CatalogURLProtocol.response(for: request, statusCode: 500, body: "")
            }
        }

        let manager = makeManager(
            endpoint: URL(string: "https://provider.test/models")!,
            cacheURL: cacheURL
        )
        let initial = try await manager.refresh()
        let recreatedManager = makeManager(
            endpoint: URL(string: "https://provider.test/models")!,
            cacheURL: cacheURL
        )
        let refreshed = try await recreatedManager.refresh()

        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(refreshed.models, initial.models)
        XCTAssertEqual(refreshed.etag, "\"catalog-v1\"")
        XCTAssertGreaterThanOrEqual(refreshed.fetchedAt, initial.fetchedAt)
        let recordedDiagnostics = await recreatedManager.lastDiagnostics
        let diagnostics = try XCTUnwrap(recordedDiagnostics)
        XCTAssertEqual(diagnostics.resolutionSource, .notModified)
        XCTAssertEqual(diagnostics.catalogSource, .codex)
        XCTAssertEqual(diagnostics.fallbackUsage, .none)
        XCTAssertFalse(diagnostics.isStale)
        XCTAssertNil(diagnostics.errorDescription)
    }

    func testPlatformCatalogMakesMergedFallbackUsageVisible() async throws {
        CatalogURLProtocol.handler = { request in
            CatalogURLProtocol.response(
                for: request,
                json: #"{"data":[{"id":"gpt-platform","created":123}]}"#
            )
        }

        let manager = makeManager(endpoint: URL(string: "https://api.openai.test/v1/models")!)
        let snapshot = try await manager.refresh()

        XCTAssertEqual(snapshot.source, .openAI)
        XCTAssertEqual(snapshot.fallbackUsage, .merged)
        XCTAssertTrue(snapshot.models.contains { $0.slug == "gpt-platform" })
        XCTAssertTrue(snapshot.models.contains { $0.slug == OpenAIModel.gpt56Sol.rawValue })
        let recordedDiagnostics = await manager.lastDiagnostics
        let diagnostics = try XCTUnwrap(recordedDiagnostics)
        XCTAssertEqual(diagnostics.catalogSource, .openAI)
        XCTAssertEqual(diagnostics.fallbackUsage, .merged)
        XCTAssertTrue(diagnostics.usesBundledFallback)
    }

    func testConcurrentRefreshesShareOneNetworkRequest() async throws {
        let requestCount = CatalogLocked(0)
        CatalogURLProtocol.handler = { request in
            requestCount.withValue { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.15)
            return CatalogURLProtocol.response(
                for: request,
                headers: ["ETag": "single-flight"],
                json: Self.catalogJSON(model: "gpt-single-flight")
            )
        }

        let manager = makeManager(endpoint: URL(string: "https://provider.test/models")!)
        let snapshots = try await withThrowingTaskGroup(of: OpenAIModelCatalogSnapshot.self) { group in
            for _ in 0..<12 {
                group.addTask { try await manager.refresh() }
            }
            var results: [OpenAIModelCatalogSnapshot] = []
            for try await snapshot in group {
                results.append(snapshot)
            }
            return results
        }

        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(snapshots.count, 12)
        XCTAssertTrue(snapshots.allSatisfy { $0.models.map(\.slug) == ["gpt-single-flight"] })
    }

    func testOnlineIfUncachedReturnsStaleCatalogWhileRefreshRuns() async throws {
        let requestCount = CatalogLocked(0)
        CatalogURLProtocol.handler = { request in
            let count = requestCount.withValue { value in
                value += 1
                return value
            }
            if count == 1 {
                return CatalogURLProtocol.response(
                    for: request,
                    headers: ["ETag": "v1"],
                    json: Self.catalogJSON(model: "gpt-v1")
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "v1")
            Thread.sleep(forTimeInterval: 0.25)
            return CatalogURLProtocol.response(
                for: request,
                headers: ["ETag": "v2"],
                json: Self.catalogJSON(model: "gpt-v2")
            )
        }

        let manager = makeManager(
            endpoint: URL(string: "https://provider.test/models")!,
            cacheTTL: -1
        )
        _ = try await manager.refresh()

        let start = Date()
        let stale = await manager.catalog(.onlineIfUncached)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(stale.models.map(\.slug), ["gpt-v1"])
        XCTAssertLessThan(elapsed, 0.15)
        let recordedDiagnostics = await manager.lastDiagnostics
        let staleDiagnostics = try XCTUnwrap(recordedDiagnostics)
        XCTAssertEqual(staleDiagnostics.resolutionSource, .staleWhileRevalidate)
        XCTAssertTrue(staleDiagnostics.isStale)
        XCTAssertTrue(staleDiagnostics.isRefreshInFlight)

        let refreshed = await manager.catalog(.online)
        XCTAssertEqual(refreshed.models.map(\.slug), ["gpt-v2"])
        XCTAssertEqual(requestCount.value, 2)
    }

    func testDiskCacheRejectsDifferentEndpointAndClientVersion() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let requestCount = CatalogLocked(0)
        CatalogURLProtocol.handler = { request in
            requestCount.withValue { $0 += 1 }
            return CatalogURLProtocol.response(
                for: request,
                headers: ["ETag": "provider-a"],
                json: Self.catalogJSON(model: "gpt-provider-a")
            )
        }

        let providerA = makeManager(
            endpoint: URL(string: "https://provider-a.test/models")!,
            clientVersion: "1.0.0",
            cacheURL: cacheURL
        )
        let networkSnapshot = try await providerA.refresh()
        XCTAssertNotNil(networkSnapshot.endpointIdentity)

        let otherEndpoint = makeManager(
            endpoint: URL(string: "https://provider-b.test/models")!,
            clientVersion: "1.0.0",
            cacheURL: cacheURL
        )
        let endpointResult = await otherEndpoint.catalog(.offline)
        XCTAssertEqual(endpointResult.source, .fallback)
        XCTAssertFalse(endpointResult.models.contains { $0.slug == "gpt-provider-a" })
        let recordedDiagnostics = await otherEndpoint.lastDiagnostics
        let endpointDiagnostics = try XCTUnwrap(recordedDiagnostics)
        XCTAssertEqual(endpointDiagnostics.resolutionSource, .bundledFallback)
        XCTAssertEqual(endpointDiagnostics.fallbackUsage, .exclusive)
        XCTAssertTrue(endpointDiagnostics.usesBundledFallback)

        let otherVersion = makeManager(
            endpoint: URL(string: "https://provider-a.test/models")!,
            clientVersion: "2.0.0",
            cacheURL: cacheURL
        )
        let versionResult = await otherVersion.catalog(.offline)
        XCTAssertEqual(versionResult.source, .fallback)
        XCTAssertFalse(versionResult.models.contains { $0.slug == "gpt-provider-a" })
        XCTAssertEqual(requestCount.value, 1)
    }

    func testInvalidRemoteAndCorruptDiskCatalogsAreRejected() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let requestCount = CatalogLocked(0)
        CatalogURLProtocol.handler = { request in
            let count = requestCount.withValue { value in
                value += 1
                return value
            }
            switch count {
            case 1:
                return CatalogURLProtocol.response(
                    for: request,
                    headers: ["ETag": "valid"],
                    json: Self.catalogJSON(model: "gpt-valid")
                )
            case 2:
                return CatalogURLProtocol.response(for: request, json: #"{"models":[]}"#)
            default:
                return CatalogURLProtocol.response(
                    for: request,
                    json: #"{"models":[{"slug":"  ","visibility":"list"}]}"#
                )
            }
        }

        let manager = makeManager(
            endpoint: URL(string: "https://provider.test/models")!,
            cacheURL: cacheURL
        )
        _ = try await manager.refresh()

        do {
            _ = try await manager.refresh()
            XCTFail("Expected an empty catalog to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("empty catalog"))
        }
        let recordedDiagnostics = await manager.lastDiagnostics
        let emptyDiagnostics = try XCTUnwrap(recordedDiagnostics)
        XCTAssertEqual(emptyDiagnostics.resolutionSource, .refreshFailure)
        XCTAssertNotNil(emptyDiagnostics.errorDescription)

        do {
            _ = try await manager.refresh()
            XCTFail("Expected an invalid model identifier to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("valid model identifier"))
        }

        let retained = await manager.catalog(.offline)
        XCTAssertEqual(retained.models.map(\.slug), ["gpt-valid"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var corrupt = try decoder.decode(OpenAIModelCatalogSnapshot.self, from: Data(contentsOf: cacheURL))
        corrupt.models = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(corrupt).write(to: cacheURL, options: .atomic)

        let freshManager = makeManager(
            endpoint: URL(string: "https://provider.test/models")!,
            cacheURL: cacheURL
        )
        let corruptResult = await freshManager.catalog(.offline)
        XCTAssertEqual(corruptResult.source, .fallback)
        XCTAssertFalse(corruptResult.models.isEmpty)
    }

    private func makeManager(
        endpoint: URL,
        clientVersion: String = "test-client",
        cacheURL: URL? = nil,
        cacheTTL: TimeInterval = 300
    ) -> OpenAIModelsManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return OpenAIModelsManager(
            auth: CatalogAuthProvider(),
            options: OpenAIModelsManager.Options(
                endpoint: endpoint,
                clientVersion: clientVersion,
                cacheURL: cacheURL,
                cacheTTL: cacheTTL
            ),
            session: URLSession(configuration: configuration)
        )
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAIModelsManagerHardeningTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("models.json")
    }

    private static func catalogJSON(model: String) -> String {
        #"{"models":[{"slug":"\#(model)","display_name":"Test","visibility":"list","priority":1}]}"#
    }
}

private struct CatalogAuthProvider: AuthorizationProvider {
    func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer test"]
    }
}

private final class CatalogLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        json: String
    ) -> (HTTPURLResponse, Data) {
        response(for: request, statusCode: statusCode, headers: headers, body: json)
    }

    static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}
