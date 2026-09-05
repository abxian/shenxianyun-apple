import Foundation
import XCTest
@testable import ShenxianyunKit

final class FailoverTests: XCTestCase {
    /// 第一个 API 地址连不上时自动换第二个——这正是内置地址表的意义。
    func testFailsOverToSecondBaseOnTransportError() async throws {
        let http = StubHTTPClient()
        http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
        http.stub("/api/verify", .init(json: [
            "success": true, "expire_time": "2026-12-31 23:59:59",
            "protected_mode": false, "imports": ["shenxianyun": true],
        ]))
        http.stub("/api/import/ticket", .init(status: 403, json: ["ok": false, "message": "x"]))

        let client = ShenxianyunClient(
            http: http, store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")
        // 先发现地址表（此时主地址还通），拿到 [api.sxnn.de, sxnn.de]
        _ = await client.refreshEndpoints()
        // 然后主地址挂掉
        http.failHost("api.sxnn.de")

        let outcome = try await client.importAccessCode("122345")

        // 能走完说明确实切到了备用地址
        XCTAssertEqual(outcome.subscriptionURL.absoluteString,
                       "https://api.sxnn.de:5443/sub/122345")
        let hosts = http.recordedHosts()
        XCTAssertTrue(hosts.contains("sxnn.de"), "应当尝试过备用地址，实际 \(hosts)")
    }

    /// 服务器明确回了业务错误说明这台是通的，**不应该**再去试别的地址：
    /// 那只会把一次失败放大成 N 次请求，还可能撞上后端限流。
    func testServerErrorDoesNotTriggerFailover() async throws {
        let http = StubHTTPClient()
        http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
        http.stub("/api/verify", .init(json: ["success": false, "message": "无效的提取码"]))

        let client = ShenxianyunClient(
            http: http, store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")
        _ = try? await client.importAccessCode("bad")

        let verifyCount = http.recordedPaths().filter { $0 == "/api/verify" }.count
        XCTAssertEqual(verifyCount, 1, "业务错误不该触发地址轮询")
    }

    /// 地址发现失败不能挡住主流程——它只是优化，退回引导地址即可。
    func testEndpointDiscoveryFailureIsNonFatal() async throws {
        let http = StubHTTPClient()
        // 故意不 stub /api/endpoints，让它抛传输错误
        http.stub("/api/verify", .init(json: [
            "success": true, "expire_time": "2026-12-31 23:59:59",
            "protected_mode": false, "imports": ["shenxianyun": true],
        ]))
        http.stub("/api/import/ticket", .init(status: 403, json: ["ok": false, "message": "x"]))

        let client = ShenxianyunClient(
            http: http, store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")

        let outcome = try await client.importAccessCode("122345")
        XCTAssertEqual(outcome.subscriptionURL.absoluteString,
                       "https://api.sxnn.de:5443/sub/122345")
    }
}

final class StateTests: XCTestCase {
    /// clientID 一旦生成就必须稳定——后台的设备数与风控都挂在它上面。
    func testClientIDIsStableAcrossReads() {
        let store = InMemoryStore()
        let state = ShenxianyunState(store: store)
        let first = state.clientID()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, state.clientID())
        XCTAssertEqual(first, ShenxianyunState(store: store).clientID())
    }

    /// 重置只清提取码与激活凭据，**保留 clientID**：
    /// 换了 id 后台就会把同一台设备算成新设备。
    func testResetKeepsClientID() async {
        let store = InMemoryStore()
        let client = ShenxianyunClient(
            http: StubHTTPClient(), store: store,
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")

        let id = await client.stableClientID()
        await client.reset()
        let after = await client.stableClientID()
        XCTAssertEqual(id, after)
    }

    /// 激活凭据要能完整存取——Extension 进程靠它做遥测。
    func testActivationRoundTripsThroughStore() {
        let store = InMemoryStore()
        let state = ShenxianyunState(store: store)
        let activation = ShenxianyunActivation(
            code: "122345", expiresAt: "2026-12-31 23:59:59",
            deviceToken: "T", subscriptionURL: URL(string: "https://x/managed-sub/m")!,
            deviceID: "d", limitMode: "device")

        state.activation = activation
        XCTAssertEqual(ShenxianyunState(store: store).activation, activation)

        state.clearActivation()
        XCTAssertNil(ShenxianyunState(store: store).activation)
    }
}

final class PaymentURLTests: XCTestCase {
    func testRenewURLCarriesSavedCode() async throws {
        let http = StubHTTPClient()
        http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
        http.stub("/api/verify", .init(json: [
            "success": true, "expire_time": "2026-12-31 23:59:59",
            "protected_mode": false, "imports": ["shenxianyun": true],
        ]))
        http.stub("/api/import/ticket", .init(status: 403, json: ["ok": false, "message": "x"]))

        let client = ShenxianyunClient(
            http: http, store: InMemoryStore(),
            bootstrapAPI: URL(string: "https://api.sxnn.de:5443")!, platform: "ios")
        _ = try await client.importAccessCode("122345")

        let renew = await client.renewURL()
        XCTAssertTrue(renew.absoluteString.contains("action=renew"))
        XCTAssertTrue(renew.absoluteString.contains("code=122345"))

        let purchase = await client.purchaseURL()
        XCTAssertTrue(purchase.absoluteString.contains("action=new"))
        XCTAssertFalse(purchase.absoluteString.contains("code="))
    }
}
