import Foundation

/// Optional remote accounts. Only dashboard credentials are read; Claude OAuth
/// credentials and refresh tokens stay on the CCS server.
struct CCSQuotaConfiguration: Decodable {
    struct Account: Decodable {
        let email: String
        let pool: String
        let name: String
        var id: String { "ccs-" + email.lowercased() }
        var displayName: String { pool + " · " + name }
    }
    let dashboardURL: URL
    let credentialsFile: String
    let accounts: [Account]

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codenotch/ccs.json")
    }

    static func providers() -> [CCSQuotaProvider] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
            guard ["http", "https"].contains(config.dashboardURL.scheme),
                  config.dashboardURL.host != nil,
                  config.dashboardURL.user == nil, config.dashboardURL.password == nil,
                  config.dashboardURL.query == nil, config.dashboardURL.fragment == nil,
                  Set(config.accounts.map(\.id)).count == config.accounts.count else {
                throw UsageProviderError.badResponse(status: 400)
            }
            let client = CCSQuotaClient(configuration: config)
            var pools: [String] = []
            for account in config.accounts where !pools.contains(account.pool) { pools.append(account.pool) }
            return pools.map { pool in
                CCSQuotaProvider(pool: pool, accounts: config.accounts.filter { $0.pool == pool },
                                 client: client, dashboardURL: config.dashboardURL)
            }
        } catch {
            Log.usage.error("CCS configuration could not be loaded; check ~/.config/codenotch/ccs.json")
            return []
        }
    }
}

private final class CCSNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor CCSQuotaClient {
    private struct Credentials: Decodable, Encodable { let username: String; let password: String }
    private let configuration: CCSQuotaConfiguration
    private let session: URLSession
    private let redirects = CCSNoRedirects()
    private var loginTask: Task<Void, Error>?
    private var authenticated = false
    private var loginRetryAfter = Date.distantPast
    private var cache: [String: (date: Date, data: Data)] = [:]
    private var retryAfter: [String: Date] = [:]

    init(configuration: CCSQuotaConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    private func request(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else {
            throw UsageProviderError.badResponse(status: 0)
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw UsageProviderError.needsAuth
        case 429:
            throw UsageProviderError.rateLimited(
                retryAfter: max(60, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300))
        default: throw UsageProviderError.badResponse(status: http.statusCode)
        }
    }

    private func login() async throws {
        if let task = loginTask { return try await task.value }
        guard !authenticated else { return }
        guard Date() >= loginRetryAfter else { throw UsageProviderError.needsAuth }
        // All account rings share one login, avoiding CCS's five-attempt limit.
        let task = Task {
            let path = (configuration.credentialsFile as NSString).expandingTildeInPath
            let credentials = try JSONDecoder().decode(Credentials.self,
                                                        from: Data(contentsOf: URL(fileURLWithPath: path)))
            var req = URLRequest(url: configuration.dashboardURL.appendingPathComponent("api/auth/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(credentials)
            _ = try await request(req)
        }
        loginTask = task
        do {
            try await task.value
            authenticated = true
            loginTask = nil
        } catch {
            loginTask = nil
            loginRetryAfter = Date().addingTimeInterval(15 * 60)
            throw error
        }
    }

    func quota(for email: String) async throws -> Data {
        if let held = cache[email], Date().timeIntervalSince(held.date) < 120 { return held.data }
        if let until = retryAfter[email], until > Date() {
            throw UsageProviderError.rateLimited(retryAfter: until.timeIntervalSinceNow)
        }
        try await login()
        let url = configuration.dashboardURL.appendingPathComponent("api/cliproxy/quota/claude")
            .appendingPathComponent(email)
        do {
            let data = try await request(URLRequest(url: url))
            // Never cache an HTTP-200 quota error as a successful zero reading.
            _ = try CCSQuotaReading.parse(data, expectedAccount: email)
            cache[email] = (Date(), data)
            return data
        } catch UsageProviderError.needsAuth {
            authenticated = false
            throw UsageProviderError.needsAuth
        } catch UsageProviderError.rateLimited(let delay) {
            retryAfter[email] = Date().addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
    }
}

struct CCSQuotaReading {
    let windows: [LimitWindow]
    let updatedAt: Date

    static func parse(_ data: Data, expectedAccount: String) throws -> Self {
        struct Reply: Decodable {
            struct Window: Decodable {
                let rateLimitType: String
                let label: String
                let usedPercent: Double?
                let resetAt: String?
            }
            let success: Bool
            let accountId: String?
            let windows: [Window]?
            let lastUpdated: Double?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success else {
            throw UsageProviderError.apiError(L10n.t("CCS could not read this account's quota."))
        }
        guard reply.accountId == expectedAccount, let updated = reply.lastUpdated,
              updated.isFinite, updated > 0, let values = reply.windows else {
            throw UsageProviderError.badResponse(status: 502)
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDates = ISO8601DateFormatter()
        let windows = try values.map { value -> LimitWindow in
            guard let percent = value.usedPercent, percent.isFinite, percent >= 0 else {
                throw UsageProviderError.badResponse(status: 502)
            }
            let reset = value.resetAt.flatMap { dates.date(from: $0) ?? plainDates.date(from: $0) }
            let label: String
            switch value.rateLimitType {
            case "five_hour": label = L10n.t("Current session")
            case "seven_day": label = L10n.t("All models")
            default: label = value.label
            }
            return LimitWindow(id: value.rateLimitType, label: label,
                               usedFraction: percent / 100, resetsAt: reset,
                               duration: value.rateLimitType == "five_hour" ? 5 * 3600
                                   : value.rateLimitType == "seven_day" || value.rateLimitType.hasPrefix("seven_day_")
                                       ? 7 * 86400 : nil)
        }
        return Self(windows: windows, updatedAt: Date(timeIntervalSince1970: updated / 1000))
    }
}

struct CCSQuotaProvider: UsageProvider {
    let pool: String
    let accounts: [CCSQuotaConfiguration.Account]
    let client: CCSQuotaClient
    let dashboardURL: URL
    var id: String { "ccs-pool-" + pool.lowercased() }
    var displayName: String { pool }
    var glyph: ProviderGlyph { .claude }

    var signInRoute: SignInRoute {
        .guidance(L10n.t("Check the CCS dashboard connection and account authentication."))
    }
    func account() -> ProviderAccount? {
        ProviderAccount(label: accounts.map(\.email).joined(separator: ", "), plan: nil,
                        source: "CCS · " + pool, manageURL: dashboardURL)
    }
    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Fetch concurrently so one slow account cannot hold up the whole pool.
        let readings = await withTaskGroup(of: (Int, CCSQuotaReading?).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    do {
                        let data = try await client.quota(for: account.email)
                        return (index, try CCSQuotaReading.parse(data, expectedAccount: account.email))
                    } catch { return (index, nil) }
                }
            }
            var results: [(Int, CCSQuotaReading?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var windows: [LimitWindow] = []
        for (index, reading) in readings {
            let account = accounts[index]
            let stale = reading.map { Date().timeIntervalSince($0.updatedAt) > 15 * 60 } ?? false
            let title = account.name + (stale ? " · " + L10n.t("Stale") : "")
            guard let reading, !reading.windows.isEmpty else {
                windows.append(LimitWindow(id: account.id, group: title,
                                           label: L10n.t("Quota"), detail: L10n.t("Unavailable")))
                continue
            }
            windows += reading.windows.map { window in
                LimitWindow(id: account.id + ":" + window.id, group: title, label: window.label,
                            usedFraction: window.usedFraction, resetsAt: window.resetsAt,
                            duration: window.duration)
            }
        }
        // Different subscriptions do not have a common quota denominator.
        // Keep the ring neutral and show each real percentage inside its group.
        return ProviderSnapshot(id: id, displayName: pool, glyph: glyph, fidelity: .official,
                                status: .ok, windows: windows, headlineID: "pool")
    }
}
