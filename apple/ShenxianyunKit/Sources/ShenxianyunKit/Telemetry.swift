import Foundation

/// 流量计数器。后端 `/api/v2/client/traffic` 收的是**累计值**加 `counter_id` + `sequence`，
/// 不是增量——这样它才能识别客户端重启导致的计数器归零，不会把重启当成流量暴涨。
///
/// 因此每次隧道重新开始计数就要换一个 `counterID`，`sequence` 在同一个 counterID 内单调递增。
public struct TrafficCounter: Equatable, Sendable {
    public let counterID: String
    public private(set) var sequence: Int
    public private(set) var uploadTotal: Int64
    public private(set) var downloadTotal: Int64

    public init(counterID: String = UUID().uuidString) {
        self.counterID = counterID
        self.sequence = 0
        self.uploadTotal = 0
        self.downloadTotal = 0
    }

    /// 记下这一轮的累计值并推进 sequence。后端要求 `sequence >= 1`。
    public mutating func advance(uploadTotal: Int64, downloadTotal: Int64) {
        sequence += 1
        // 累计值只能增不能减；内核重启后回退的话保持旧值，避免后端把它当成异常。
        self.uploadTotal = max(self.uploadTotal, uploadTotal)
        self.downloadTotal = max(self.downloadTotal, downloadTotal)
    }
}

/// 上报节奏。**沿用族内 2026-08-16 已定案的策略，不在 Apple 线另立一套**：
/// 300 秒基础间隔 + 60 秒抖动、单飞、失败按 Retry-After 或指数退避。
public struct TelemetryPacing: Equatable, Sendable {
    public let baseInterval: TimeInterval
    public let jitter: TimeInterval
    public let maxBackoff: TimeInterval

    public static let family = TelemetryPacing(baseInterval: 300, jitter: 60, maxBackoff: 3600)

    public init(baseInterval: TimeInterval, jitter: TimeInterval, maxBackoff: TimeInterval) {
        self.baseInterval = baseInterval
        self.jitter = jitter
        self.maxBackoff = maxBackoff
    }

    /// 下一次正常上报的间隔。抖动是为了避免大量客户端同时醒来打爆后端。
    public func nextInterval(random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) })
        -> TimeInterval
    {
        baseInterval + random(0...jitter)
    }

    /// 第 n 次连续失败后的退避（n 从 1 开始）。指数增长并封顶。
    public func backoff(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return baseInterval }
        let exponential = baseInterval * pow(2, Double(min(failures, 8) - 1))
        return min(exponential, maxBackoff)
    }
}

/// 遥测的**节奏状态机**，与网络分离，因此可以完全用单元测试覆盖。
///
/// iOS 特有：隧道由系统按需拉起、后台不常驻，长时间空档是常态。
/// 所以这里不假设自己会被定时唤醒，只回答"现在该不该发"。
public actor TelemetryScheduler {
    private let pacing: TelemetryPacing
    private var consecutiveFailures = 0
    private var nextAllowed: Date
    /// 单飞：同一时刻只允许一次在途上报，避免唤醒风暴叠加。
    private var inFlight = false

    public init(pacing: TelemetryPacing = .family, now: Date = Date()) {
        self.pacing = pacing
        self.nextAllowed = now
    }

    /// 现在能不能发。能发就立刻置为在途——调用方拿到 true 就必须配一次 `finish`。
    public func beginIfDue(now: Date = Date()) -> Bool {
        guard !inFlight, now >= nextAllowed else { return false }
        inFlight = true
        return true
    }

    /// 上报成功：清空失败计数，按正常节奏排下一次。
    public func finishSuccess(now: Date = Date()) {
        inFlight = false
        consecutiveFailures = 0
        nextAllowed = now.addingTimeInterval(pacing.nextInterval())
    }

    /// 上报失败：按 Retry-After（服务端明确要求）或指数退避排下一次。
    public func finishFailure(retryAfter: TimeInterval? = nil, now: Date = Date()) {
        inFlight = false
        consecutiveFailures += 1
        let delay = retryAfter ?? pacing.backoff(afterConsecutiveFailures: consecutiveFailures)
        nextAllowed = now.addingTimeInterval(delay)
    }

    /// 隧道停止等场景：取消在途标记，避免"单飞"被永久卡住。
    /// 族内策略明确要求「取消组件时清理额外上报」。
    public func cancelInFlight() {
        inFlight = false
    }

    public var failureCount: Int { consecutiveFailures }
    public var nextAllowedDate: Date { nextAllowed }
}

extension APITransport {
    /// `POST /api/v2/client/heartbeat`。需要 `Authorization: Bearer <device_token>`。
    /// 返回体里的 `expires_at` 可用来刷新首页的到期显示。
    @discardableResult
    func heartbeat(deviceToken: String, bases: [URL]) async throws -> String? {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/v2/client/heartbeat", method: "POST",
            body: [:], deviceToken: deviceToken)
        let json = try decodeEnvelope(response)
        return json["expires_at"] as? String
    }

    /// `POST /api/v2/client/traffic`。累计值，不是增量。
    func reportTraffic(counter: TrafficCounter, deviceToken: String, bases: [URL]) async throws {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/v2/client/traffic", method: "POST",
            body: [
                "counter_id": counter.counterID,
                "sequence": counter.sequence,
                "upload_total": counter.uploadTotal,
                "download_total": counter.downloadTotal,
            ],
            deviceToken: deviceToken)
        _ = try decodeEnvelope(response)
    }

    /// `POST /api/v2/client/offline`。隧道停止时发一次，让后台的在线数及时回落。
    func reportOffline(deviceToken: String, bases: [URL]) async throws {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/v2/client/offline", method: "POST",
            body: [:], deviceToken: deviceToken)
        _ = try decodeEnvelope(response)
    }
}
