import Foundation

/// 神仙云后端的统一入口。UI 与 Network Extension 都只跟它打交道。
///
/// 它把七个契约串成三条对外可用的流程：
///
/// 1. **导入提取码** → `importAccessCode` → 拿到订阅地址（普通或受管）
/// 2. **拉订阅** → `subscriptionURL` → 交给 Hako 的 `BoxService.Start/Reload`
/// 3. **上报** → `heartbeat` / `reportTraffic` / `reportOffline`
public actor ShenxianyunClient {
    private let transport: APITransport
    private let state: ShenxianyunState
    private let bootstrapAPI: URL
    private let platform: String

    public init(
        http: ShenxianyunHTTPClient = URLSession.shared,
        store: ShenxianyunStore,
        bootstrapAPI: URL = ShenxianyunProfile.bootstrapAPI,
        platform: String = ShenxianyunProfile.platform
    ) {
        self.transport = APITransport(http: http)
        self.state = ShenxianyunState(store: store)
        self.bootstrapAPI = bootstrapAPI
        self.platform = platform
    }

    // MARK: - 契约 A：地址发现

    /// 当前该用哪些 API 地址。顺序：缓存 > 引导地址。
    private func currentBases() -> [URL] {
        if let cached = state.cachedEndpoints, !cached.apiBases.isEmpty {
            return cached.apiBases
        }
        return [bootstrapAPI]
    }

    /// 拉一次 `/api/endpoints` 并缓存。**失败不抛**——地址发现只是优化，
    /// 拿不到就继续用缓存或引导地址，不能因此把整个导入流程挡住。
    @discardableResult
    public func refreshEndpoints() async -> ShenxianyunEndpoints? {
        do {
            let response = try await transport.sendWithFailover(
                bases: currentBases(), path: "/api/endpoints")
            guard (200..<300).contains(response.status) else { return nil }
            let endpoints = try JSONDecoder().decode(
                ShenxianyunEndpoints.self, from: response.body)
            state.cachedEndpoints = endpoints
            return endpoints
        } catch {
            return nil
        }
    }

    public func endpoints() -> ShenxianyunEndpoints {
        state.cachedEndpoints ?? .bootstrap(bootstrapAPI)
    }

    // MARK: - 契约 B/C/D：导入提取码

    /// 导入结果：要么是普通订阅地址，要么是受管订阅（且已顺带拿到设备凭据）。
    public enum ImportOutcome: Sendable {
        /// 兼容模式：直接用 `/sub/<code>`。此时**没有**设备凭据，不能上报遥测。
        case plain(subscriptionURL: URL, status: AccessCodeStatus)
        /// 全保护模式：走完 ticket 链路，拿到受管订阅与设备凭据。
        case managed(ShenxianyunActivation)

        public var subscriptionURL: URL {
            switch self {
            case let .plain(url, _): return url
            case let .managed(activation): return activation.subscriptionURL
            }
        }
    }

    /// 输入提取码，走完校验 → 取订阅地址的全过程。
    ///
    /// **总是优先尝试 ticket 链路**，而不是只在 `protected_mode` 为真时才走。
    /// 原因：ticket 换来的 `device_token` 是遥测的唯一来源，兼容模式下也拿得到
    /// （后端 2026-07-26 的止血提交明确允许 `target=shenxianyun` 在兼容模式下申请 ticket）。
    /// 只有 ticket 确实不可用时才退回普通订阅——那种情况下没有遥测，属于降级。
    public func importAccessCode(_ code: String) async throws -> ImportOutcome {
        await refreshEndpoints()
        let bases = currentBases()

        let status = try await transport.verify(code: code, bases: bases)
        guard status.officialImportEnabled else {
            throw ShenxianyunError.server(ShenxianyunServerError(
                statusCode: 403, message: "官方客户端导入当前未开放，请联系客服"))
        }

        do {
            let ticket = try await transport.issueImportTicket(code: code, bases: bases)
            let activation = try await transport.exchangeImportTicket(
                ticket: ticket, clientID: state.clientID(), platform: platform, bases: bases)
            state.accessCode = code
            state.activation = activation
            return .managed(activation)
        } catch {
            // 全保护模式下没有退路：普通订阅会被后端 426 拒绝，必须把真实原因报上去。
            if status.isProtected { throw error }
            state.accessCode = code
            state.activation = nil
            return .plain(subscriptionURL: subscriptionURL(for: code), status: status)
        }
    }

    /// 契约 C：普通订阅地址。
    ///
    /// **是 `/sub/<code>`，不是 `/singbox/<code>`。**
    /// 后者是服务端把 Clash 转成 sing-box 的有损产物：只映射 6 种协议，
    /// 且丢弃后台配置的代理分组与路由规则。Hako 是 mihomo，直接吃 Clash 原文。
    public func subscriptionURL(for code: String) -> URL {
        let base = state.cachedEndpoints?.subBase ?? bootstrapAPI
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        return base.appendingPathComponent("sub").appendingPathComponent(escaped)
    }

    /// 当前该用的订阅地址：激活过就用受管地址，否则用普通地址。
    public func activeSubscriptionURL() -> URL? {
        if let activation = state.activation { return activation.subscriptionURL }
        guard let code = state.accessCode else { return nil }
        return subscriptionURL(for: code)
    }

    // MARK: - 契约 E：遥测

    /// 有没有遥测能力。没走过 ticket 就没有设备凭据。
    public var canReportTelemetry: Bool { state.activation != nil }

    @discardableResult
    public func heartbeat() async throws -> String? {
        guard let activation = state.activation else { throw ShenxianyunError.notActivated }
        return try await transport.heartbeat(
            deviceToken: activation.deviceToken, bases: currentBases())
    }

    public func reportTraffic(_ counter: TrafficCounter) async throws {
        guard let activation = state.activation else { throw ShenxianyunError.notActivated }
        try await transport.reportTraffic(
            counter: counter, deviceToken: activation.deviceToken, bases: currentBases())
    }

    public func reportOffline() async throws {
        guard let activation = state.activation else { throw ShenxianyunError.notActivated }
        try await transport.reportOffline(
            deviceToken: activation.deviceToken, bases: currentBases())
    }

    // MARK: - 契约 F：续费

    public func purchaseURL() -> URL {
        payURL(action: "new", code: nil)
    }

    public func renewURL() -> URL {
        payURL(action: "renew", code: state.accessCode)
    }

    private func payURL(action: String, code: String?) -> URL {
        let base = currentBases().first ?? bootstrapAPI
        var components = URLComponents(
            url: base.appendingPathComponent("pay"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "action", value: action)]
        if let code, !code.isEmpty { items.append(URLQueryItem(name: "code", value: code)) }
        components?.queryItems = items
        return components?.url ?? base
    }

    // MARK: - 状态

    public func savedAccessCode() -> String? { state.accessCode }
    public func savedActivation() -> ShenxianyunActivation? { state.activation }
    public func stableClientID() -> String { state.clientID() }
    public func reset() { state.clearActivation() }
}
