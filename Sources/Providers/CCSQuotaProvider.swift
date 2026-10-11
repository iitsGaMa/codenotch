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
    private var historyCache: (date: Date, accounts: [CCSUsageSummary])?
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

    func history() async throws -> [CCSUsageSummary] {
        if let held = historyCache, Date().timeIntervalSince(held.date) < 120 { return held.accounts }
        try await login()
        struct Reply: Decodable { let accounts: [CCSUsageSummary] }
        let data = try await request(URLRequest(url: configuration.dashboardURL.appendingPathComponent("api/bar/account-history")))
        let accounts = try JSONDecoder().decode(Reply.self, from: data).accounts
        historyCache = (Date(), accounts)
        return accounts
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
    let plan: CCSPlan?

    static func parse(_ data: Data, expectedAccount: String) throws -> Self {
        struct Reply: Decodable {
            struct Window: Decodable {
                let rateLimitType: String
                let label: String
                let usedPercent: Double?
                let resetAt: String?
            }
            let success: Bool
            let credits: CCSCredits?
            let cloudCredits: CCSCloudCredits?
            let plan: CCSPlan?
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
        var windows = try values.map { value -> LimitWindow in
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
        windows += reply.credits?.windows ?? []
        windows += reply.cloudCredits?.windows(now: Date()) ?? []
        return Self(windows: windows, updatedAt: Date(timeIntervalSince1970: updated / 1000), plan: reply.plan)
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
        let history = try? await client.history()
        var windows: [LimitWindow] = []
        for (index, reading) in readings {
            let account = accounts[index]
            let stale = reading.map { Date().timeIntervalSince($0.updatedAt) > 15 * 60 } ?? false
            let title = account.name + (stale ? " · " + L10n.t("Stale") : "")
            if let plan = reading?.plan?.label {
                windows.append(LimitWindow(id: account.id + ":plan", group: title,
                                           label: L10n.t("Plan"), detail: plan))
            }
            if reading?.windows.first(where: { $0.id == "five_hour" }) == nil {
                windows.append(LimitWindow(id: account.id + ":session-unknown", group: title,
                                           label: L10n.t("Current session"), detail: L10n.t("Unavailable")))
            }
            if reading?.windows.isEmpty != false {
                windows.append(LimitWindow(id: account.id, group: title,
                                           label: L10n.t("Quota"), detail: L10n.t("Unavailable")))
            }
            windows += (reading?.windows ?? []).map { window in
                LimitWindow(id: account.id + ":" + window.id, group: title, label: window.label,
                            usedFraction: window.usedFraction, detail: window.detail, resetsAt: window.resetsAt,
                            duration: window.duration)
            }
            if let usage = history?.first(where: { $0.accountId == account.email }) {
                let detail = UsageFormat.tokens(usage.tokens) + " tok · " + usage.costText
                windows.append(LimitWindow(id: account.id + ":usage", group: title,
                                           label: L10n.t("Recorded · 30d"), detail: detail))
            } else {
                windows.append(LimitWindow(id: account.id + ":usage", group: title,
                                           label: L10n.t("History"), detail: L10n.t("Unavailable")))
            }
        }
        let members = history?.filter { item in accounts.contains { $0.email == item.accountId } }
        let usage = members.flatMap { CCSUsageSummary.pool($0) }
        // Equal-weight session average: an indicator, not a shared token budget.
        let sessions = readings.compactMap { _, reading -> Double? in
            guard let reading, Date().timeIntervalSince(reading.updatedAt) <= 15 * 60 else { return nil }
            return reading.windows.first(where: { $0.id == "five_hour" })?.usedFraction.map { min(1, max(0, $0)) }
        }
        let average = sessions.isEmpty ? nil : sessions.reduce(0, +) / Double(sessions.count)
        windows.insert(LimitWindow(id: "pool", group: L10n.t("Pool estimate"),
                                   label: L10n.t("Average session usage"), usedFraction: average,
                                   detail: average == nil ? L10n.t("Unavailable") : nil), at: 0)
        windows.insert(LimitWindow(id: "pool-coverage", group: L10n.t("Pool estimate"),
                                   label: L10n.t("Known session quotas"),
                                   detail: "\(sessions.count) / \(accounts.count)"), at: 1)
        return ProviderSnapshot(id: id, displayName: pool, glyph: glyph, fidelity: .official,
                                status: .ok, windows: windows, headlineID: "pool", tokenUsage: usage?.chart,
                                ccsUsage: usage)
    }
}

/// UTC daily totals from recorded proxy requests, not subscription billing.
struct CCSUsageSummary: Decodable, Equatable {
    struct Day: Decodable, Equatable {
        let day: String
        var tokens: Int
        var cost: Double
        var requests: Int
    }
    let accountId: String
    let firstRecordedAt: String
    let lastRecordedAt: String
    let days: [Day]
    var tokens: Int { days.reduce(0) { $0 + $1.tokens } }
    var cost: Double { days.reduce(0) { $0 + $1.cost } }
    var requests: Int { days.reduce(0) { $0 + $1.requests } }
    var costText: String { String(format: "~$%.2f", cost) }
    var chart: CodexTokenUsage {
        CodexTokenUsage(dailyUsageBuckets: days.map { .init(startDate: $0.day, tokens: $0.tokens) })
    }
    static func pool(_ accounts: [Self]) -> Self? {
        guard !accounts.isEmpty else { return nil }
        var days: [String: Day] = [:]
        for account in accounts {
            for day in account.days {
                let held = days[day.day] ?? Day(day: day.day, tokens: 0, cost: 0, requests: 0)
                days[day.day] = Day(day: day.day, tokens: held.tokens + day.tokens,
                                    cost: held.cost + day.cost, requests: held.requests + day.requests)
            }
        }
        return Self(accountId: "pool", firstRecordedAt: accounts.map(\.firstRecordedAt).min()!,
                    lastRecordedAt: accounts.map(\.lastRecordedAt).max()!, days: days.values.sorted { $0.day < $1.day })
    }
}

/// Amounts explicitly returned by Claude; a spending cap is not wallet funding.
struct CCSCredits: Decodable {
    struct Amount: Decodable {
        let value: Double
        let currency: String
        var text: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.locale = L10n.locale
            return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
        }
    }
    let enabled: Bool?
    let reason: String?
    let used: Amount?
    let limit: Amount?
    let balance: Amount?
    var windows: [LimitWindow] {
        var result: [LimitWindow] = []
        if enabled == false {
            result.append(LimitWindow(id: "credits-state", label: L10n.t("Extra usage credits"),
                                      detail: reason == "out_of_credits" ? L10n.t("Unavailable") : L10n.t("Disabled")))
        } else if let used, let limit, limit.value > 0, used.currency == limit.currency {
            result.append(LimitWindow(id: "credits-spend", label: L10n.t("Extra usage spending"),
                                      usedFraction: used.value / limit.value,
                                      detail: L10n.t("Spent / cap") + " · " + used.text + " / " + limit.text))
        } else {
            if let used { result.append(LimitWindow(id: "credits-used", label: L10n.t("Extra usage spent"), detail: used.text)) }
            if let limit { result.append(LimitWindow(id: "credits-limit", label: L10n.t("Spending cap"), detail: limit.text)) }
        }
        if let balance {
            result.append(LimitWindow(id: "credits-balance", label: L10n.t("Credit balance"), detail: balance.text))
        } else if enabled == true {
            result.append(LimitWindow(id: "credits-balance", label: L10n.t("Credit balance"), detail: L10n.t("Not reported")))
        }
        return result
    }
}

struct CCSPlan: Decodable {
    let organizationType: String?
    let rateLimitTier: String?
    var label: String? {
        let base: String
        switch organizationType {
        case "claude_team": base = "Team"
        case "claude_enterprise": base = "Enterprise"
        case "claude_max": base = "Max"
        case "claude_pro": base = "Pro"
        case "claude_free": base = "Free"
        default: return nil
        }
        switch rateLimitTier {
        case "default_claude_max_5x": return base + " · 5×"
        case "default_claude_max_20x": return base + " · 20×"
        default: return base
        }
    }
}

/// Promotional cloud-session credits, separate from API Console funding.
struct CCSCloudCredits: Decodable {
    let remainingDollars: Double
    let expiresAt: String?
    let locked: Bool

    func windows(now: Date) -> [LimitWindow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = expiresAt.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let expired = expiry.map { $0 <= now } ?? false
        let balance = expired ? L10n.t("Expired") : locked ? L10n.t("Unavailable")
            : CCSCredits.Amount(value: remainingDollars, currency: "USD").text
        var rows = [LimitWindow(id: "cloud-credits", label: L10n.t("Cloud credits"), detail: balance)]
        if let expiry {
            let date = DateFormatter()
            date.locale = L10n.locale
            date.dateStyle = .medium
            date.timeStyle = .short
            rows.append(LimitWindow(id: "cloud-expiry", label: L10n.t("Expiration"), detail: date.string(from: expiry)))
        }
        return rows
    }
}
