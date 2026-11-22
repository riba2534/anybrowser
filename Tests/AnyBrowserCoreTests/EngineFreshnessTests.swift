@testable import AnyBrowserCore
import Foundation
import Testing

@Suite("Engine freshness", .serialized)
@MainActor
struct EngineFreshnessTests {
    private func freshness() -> EngineFreshness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VersionHistoryStub.self]
        return EngineFreshness(configuration: configuration)
    }

    @Test("The newest stable major is read from VersionHistory and kept for a day")
    func readsAndCaches() async throws {
        VersionHistoryStub.requests = []
        VersionHistoryStub.respond = { _ in
            (200, Data(#"{"versions":[{"version":"158.0.7600.12"},{"version":"159.0.7700.3"},{"version":"9.1"}],"nextPageToken":""}"#.utf8))
        }
        let freshness = freshness()
        #expect(freshness.majorsBehind(engine: 148) == nil)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        await freshness.refresh(now: start)
        #expect(freshness.stableMajor == 159)
        #expect(freshness.majorsBehind(engine: 148) == 11)
        #expect(freshness.majorsBehind(engine: 160) == 0)
        let request = try #require(VersionHistoryStub.requests.first)
        #expect(request.url == EngineFreshness.stableVersions)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)

        await freshness.refresh(now: start.addingTimeInterval(23 * 3600))
        #expect(freshness.requests == 1)
        VersionHistoryStub.respond = { _ in (200, Data(#"{"versions":[{"version":"160.0.1.2"}]}"#.utf8)) }
        await freshness.refresh(now: start.addingTimeInterval(25 * 3600))
        #expect(freshness.requests == 2)
        #expect(freshness.stableMajor == 160)
    }

    @Test("A failed lookup tells nothing and is not retried for an hour")
    func failuresWait() async {
        VersionHistoryStub.requests = []
        VersionHistoryStub.respond = { _ in (503, Data()) }
        let freshness = freshness()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        await freshness.refresh(now: start)
        #expect(freshness.stableMajor == nil)
        await freshness.refresh(now: start.addingTimeInterval(30 * 60))
        #expect(freshness.requests == 1)

        VersionHistoryStub.respond = { _ in (200, Data(#"{"versions":"none"}"#.utf8)) }
        await freshness.refresh(now: start.addingTimeInterval(61 * 60))
        #expect(freshness.requests == 2)
        #expect(freshness.majorsBehind() == nil)

        // A good answer after failures replaces nothing it should not.
        VersionHistoryStub.respond = { _ in (200, Data(#"{"versions":[{"version":"150.0.1.1"}]}"#.utf8)) }
        await freshness.refresh(now: start.addingTimeInterval(3 * 3600))
        #expect(freshness.majorsBehind(engine: 148) == 2)
        VersionHistoryStub.respond = { _ in (500, Data()) }
        await freshness.refresh(now: start.addingTimeInterval(28 * 3600))
        #expect(freshness.requests == 4)
        #expect(freshness.majorsBehind(engine: 148) == 2)
    }

    @Test("Response bodies without versions give no major")
    func parsing() {
        #expect(EngineFreshness.stableMajor(in: Data("[]".utf8)) == nil)
        #expect(EngineFreshness.stableMajor(in: Data(#"{"versions":[]}"#.utf8)) == nil)
        #expect(EngineFreshness.stableMajor(in: Data(#"{"versions":[{"version":"x.1"},{"version":"151.2"}]}"#.utf8)) == 151)
    }
}

private final class VersionHistoryStub: URLProtocol {
    static var respond: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.respond(request)
        if let response = HTTPURLResponse(url: request.url ?? EngineFreshness.stableVersions, statusCode: status,
                                          httpVersion: "HTTP/1.1", headerFields: [:]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
