import XCTest
import SwiftUI
@testable import Codenotch

final class CCSQuotaProviderTests: XCTestCase {
    @MainActor
    func testRemoteAccountRetainsPoolWindowsAndReusesDashboardSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"username":"test","password":"test"}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let account = CCSQuotaConfiguration.Account(email: "one@example.com", pool: "Animou", name: "One")
        let second = CCSQuotaConfiguration.Account(email: "two@example.com", pool: "Animou", name: "Two")
        let unavailable = CCSQuotaConfiguration.Account(email: "missing@example.com", pool: "Animou", name: "Missing")
        let config = CCSQuotaConfiguration(dashboardURL: URL(string: "https://ccs.test")!,
                                          credentialsFile: file.path, accounts: [account, second, unavailable])
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [CCSStub.self]
        CCSStub.paths = []
        let client = CCSQuotaClient(configuration: config, session: URLSession(configuration: network))
        let provider = CCSQuotaProvider(pool: "Animou", accounts: [account, second, unavailable], client: client, dashboardURL: config.dashboardURL)
        let snapshot = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.displayName, "Animou")
        XCTAssertEqual(snapshot.headlineText, "Animou")
        XCTAssertEqual(snapshot.windows.first?.group, "One")
        XCTAssertEqual(snapshot.windows.map(\.group), ["One", "One", "Two", "Two", "Missing"])
        XCTAssertNil(snapshot.windows.last?.usedFraction)
        XCTAssertEqual(snapshot.windows.last?.detail, L10n.t("Unavailable"))
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.25)
        XCTAssertEqual(snapshot.windows[3].usedFraction, 0.7)
        XCTAssertNotNil(snapshot.windows.first?.resetsAt)
        XCTAssertNil(snapshot.weeklyID)
        XCTAssertEqual(snapshot.windows.first?.label, L10n.t("Current session"))
        XCTAssertEqual(snapshot.windows[3].label, L10n.t("All models"))
        XCTAssertEqual(snapshot.windows.first?.duration, 5 * 3600)
        XCTAssertEqual(snapshot.windows[3].duration, 7 * 86400)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(CCSStub.paths.filter { $0 == "/api/auth/login" }.count, 1)
        XCTAssertEqual(CCSStub.paths.filter { $0.hasSuffix("one@example.com") }.count, 1)
        let renderer = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date(), direction: .trailing)
            .environment(\.colorScheme, .dark)
            .environment(\.notchSurfaceStyle, .solid))
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/codenotch-pool-preview.png"))
    }

    func testUnavailableQuotaNeverBecomesAnEmptyAccount() throws {
        let data = Data(#"{"success":false,"accountId":"one@example.com","error":"unauthorized"}"#.utf8)
        XCTAssertThrowsError(try CCSQuotaReading.parse(data, expectedAccount: "one@example.com")) { error in
            guard case UsageProviderError.apiError = error else {
                return XCTFail("Expected a visible quota failure, got \(error)")
            }
        }
    }
}

private final class CCSStub: URLProtocol, @unchecked Sendable {
    static var paths: [String] = []
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url!.path)
        Self.lock.unlock()
        let body: String
        if request.url!.path == "/api/auth/login" {
            body = #"{"success":true}"#
        } else if request.url!.lastPathComponent == "missing@example.com" {
            body = #"{"success":false}"#
        } else {
            body = """
            {"success":true,"accountId":"\(request.url!.lastPathComponent)","lastUpdated":\(Date().timeIntervalSince1970 * 1000),
             "windows":[{"rateLimitType":"five_hour","label":"Session limit","usedPercent":25,"resetAt":"2026-10-12T00:00:00.000Z"},
                        {"rateLimitType":"seven_day","label":"Weekly limit","usedPercent":70,"resetAt":"2026-10-16T00:00:00Z"}]}
            """
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
