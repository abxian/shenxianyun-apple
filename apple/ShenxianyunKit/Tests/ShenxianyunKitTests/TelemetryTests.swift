import Foundation
import XCTest
@testable import ShenxianyunKit

final class TelemetryPacingTests: XCTestCase {
    /// 族内 2026-08-16 已定案：300 秒基础间隔 + 60 秒抖动。
    /// Apple 线沿用，不另立一套——这条测试就是防止有人顺手改小。
    func testFamilyPacingIsThreeHundredPlusJitter() {
        let pacing = TelemetryPacing.family
        XCTAssertEqual(pacing.baseInterval, 300)
        XCTAssertEqual(pacing.jitter, 60)

        XCTAssertEqual(pacing.nextInterval(random: { $0.lowerBound }), 300)
        XCTAssertEqual(pacing.nextInterval(random: { $0.upperBound }), 360)
    }

    func testBackoffGrowsExponentiallyAndIsCapped() {
        let pacing = TelemetryPacing.family
        XCTAssertEqual(pacing.backoff(afterConsecutiveFailures: 1), 300)
        XCTAssertEqual(pacing.backoff(afterConsecutiveFailures: 2), 600)
        XCTAssertEqual(pacing.backoff(afterConsecutiveFailures: 3), 1200)
        // 封顶，不能无限增长到几天后才重试
        XCTAssertEqual(pacing.backoff(afterConsecutiveFailures: 99), pacing.maxBackoff)
    }
}

final class TelemetrySchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstReportIsImmediatelyDue() async {
        let scheduler = TelemetryScheduler(now: t0)
        let due = await scheduler.beginIfDue(now: t0)
        XCTAssertTrue(due)
    }

    /// 单飞：在途期间不允许再发一次，否则 iOS 的唤醒风暴会叠加成并发请求。
    func testSingleFlightBlocksConcurrentReports() async {
        let scheduler = TelemetryScheduler(now: t0)
        let first = await scheduler.beginIfDue(now: t0)
        let second = await scheduler.beginIfDue(now: t0)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testSuccessSchedulesNextWithinPacingWindow() async {
        let scheduler = TelemetryScheduler(now: t0)
        _ = await scheduler.beginIfDue(now: t0)
        await scheduler.finishSuccess(now: t0)

        let tooSoon = await scheduler.beginIfDue(now: t0.addingTimeInterval(299))
        XCTAssertFalse(tooSoon)

        // 300 + 抖动(≤60)，361 秒后一定过了窗口
        let later = await scheduler.beginIfDue(now: t0.addingTimeInterval(361))
        XCTAssertTrue(later)

        let failures = await scheduler.failureCount
        XCTAssertEqual(failures, 0)
    }

    /// 服务端明确给了 Retry-After 就必须听它的，不能用自己的退避覆盖。
    func testRetryAfterOverridesBackoff()  async {
        let scheduler = TelemetryScheduler(now: t0)
        _ = await scheduler.beginIfDue(now: t0)
        await scheduler.finishFailure(retryAfter: 30, now: t0)

        let tooSoon = await scheduler.beginIfDue(now: t0.addingTimeInterval(29))
        XCTAssertFalse(tooSoon)
        let due = await scheduler.beginIfDue(now: t0.addingTimeInterval(31))
        XCTAssertTrue(due)
    }

    func testConsecutiveFailuresBackOff() async {
        let scheduler = TelemetryScheduler(now: t0)
        _ = await scheduler.beginIfDue(now: t0)
        await scheduler.finishFailure(now: t0)
        let afterFirst = await scheduler.nextAllowedDate
        XCTAssertEqual(afterFirst, t0.addingTimeInterval(300))

        _ = await scheduler.beginIfDue(now: afterFirst)
        await scheduler.finishFailure(now: afterFirst)
        let afterSecond = await scheduler.nextAllowedDate
        XCTAssertEqual(afterSecond, afterFirst.addingTimeInterval(600))
    }

    /// 族内策略要求「取消组件时清理额外上报」。不清的话单飞标记会永久卡住，
    /// 隧道重启后再也发不出心跳。
    func testCancelReleasesSingleFlight() async {
        let scheduler = TelemetryScheduler(now: t0)
        _ = await scheduler.beginIfDue(now: t0)
        await scheduler.cancelInFlight()
        let due = await scheduler.beginIfDue(now: t0)
        XCTAssertTrue(due)
    }
}

final class TrafficCounterTests: XCTestCase {
    /// 后端收的是**累计值** + counter_id + sequence，靠这个识别客户端重启，
    /// 不会把重启当成流量暴涨。sequence 必须从 1 开始。
    func testSequenceStartsAtOneAndAccumulates() {
        var counter = TrafficCounter(counterID: "c1")
        XCTAssertEqual(counter.sequence, 0)

        counter.advance(uploadTotal: 100, downloadTotal: 200)
        XCTAssertEqual(counter.sequence, 1)
        XCTAssertEqual(counter.uploadTotal, 100)

        counter.advance(uploadTotal: 350, downloadTotal: 900)
        XCTAssertEqual(counter.sequence, 2)
        XCTAssertEqual(counter.uploadTotal, 350)
        XCTAssertEqual(counter.downloadTotal, 900)
    }

    /// 内核重启后读数会回退。累计值只能增不能减，否则后端会看到非法输入。
    func testTotalsNeverGoBackwards() {
        var counter = TrafficCounter(counterID: "c1")
        counter.advance(uploadTotal: 500, downloadTotal: 500)
        counter.advance(uploadTotal: 10, downloadTotal: 10)   // 内核重启

        XCTAssertEqual(counter.uploadTotal, 500)
        XCTAssertEqual(counter.downloadTotal, 500)
        XCTAssertEqual(counter.sequence, 2)
    }
}

final class TelemetryRequestTests: XCTestCase {
    /// 遥测必须带 `Authorization: Bearer <device_token>`，
    /// 后端 authenticated_device() 靠它查 device_credentials 表。
    func testReportsCarryDeviceBearerToken() async throws {
        let http = StubHTTPClient()
        http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
        http.stub("/api/verify", .init(json: [
            "success": true, "expire_time": "2026-12-31 23:59:59",
            "protected_mode": true, "imports": ["shenxianyun": true],
        ]))
        http.stub("/api/import/ticket", .init(json: [
            "ok": true, "launch_url": "/import/launch/T1", "expires_in": 120,
        ]))
        http.stub("/api/import/exchange", .init(json: [
            "ok": true, "name": "122345", "expires_at": "2026-12-31 23:59:59",
            "device_token": "SECRET-TOKEN",
            "subscription_url": "https://api.sxnn.de:5443/managed-sub/M1",
            "device_id": "dev-1",
        ]))
        http.stub("/api/v2/client/heartbeat", .init(json: [
            "ok": true, "online": true, "expires_at": "2026-12-31 23:59:59",
        ]))
        http.stub("/api/v2/client/traffic", .init(json: ["ok": true]))

        let client = ShenxianyunClient(
            http: http, store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")
        _ = try await client.importAccessCode("122345")

        let expires = try await client.heartbeat()
        XCTAssertEqual(expires, "2026-12-31 23:59:59")
        XCTAssertEqual(
            http.request(forPath: "/api/v2/client/heartbeat")?
                .value(forHTTPHeaderField: "Authorization"),
            "Bearer SECRET-TOKEN")

        var counter = TrafficCounter(counterID: "c-1")
        counter.advance(uploadTotal: 1024, downloadTotal: 4096)
        try await client.reportTraffic(counter)

        let body = try XCTUnwrap(http.request(forPath: "/api/v2/client/traffic")?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["counter_id"] as? String, "c-1")
        XCTAssertEqual(json["sequence"] as? Int, 1)
        XCTAssertEqual(json["upload_total"] as? Int, 1024)
        XCTAssertEqual(json["download_total"] as? Int, 4096)
    }

    /// 没激活过就没有设备凭据，此时上报应当明确报"未激活"，而不是发一个没鉴权的请求。
    func testTelemetryWithoutActivationThrows() async {
        let client = ShenxianyunClient(
            http: StubHTTPClient(), store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")
        do {
            _ = try await client.heartbeat()
            XCTFail("未激活时不应发出请求")
        } catch let error as ShenxianyunError {
            XCTAssertEqual(error, .notActivated)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
