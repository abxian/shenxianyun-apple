import Foundation
import XCTest
@testable import ShenxianyunKit

private let bootstrap = URL(string: "https://api.sxnn.de:5443")!

private func makeClient(_ http: StubHTTPClient) -> ShenxianyunClient {
    ShenxianyunClient(
        http: http, store: InMemoryStore(), bootstrapAPI: bootstrap, platform: "ios")
}

private func stubHappyPath(_ http: StubHTTPClient, protected: Bool = false) {
    http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
    http.stub("/api/verify", .init(json: [
        "success": true, "filename": "122345", "expire_time": "2026-12-31 23:59:59",
        "protected_mode": protected,
        "imports": ["shenxianyun": true, "shadowrocket": false, "clash": false],
    ]))
    http.stub("/api/import/ticket", .init(json: [
        "ok": true, "target": "shenxianyun",
        "launch_url": "/import/launch/TICKET-ABC", "expires_in": 120,
    ]))
    http.stub("/api/import/exchange", .init(json: [
        "ok": true, "name": "122345", "expires_at": "2026-12-31 23:59:59",
        "device_token": "DEVTOKEN-XYZ",
        "subscription_url": "https://api.sxnn.de:5443/managed-sub/MANAGED-TOKEN",
        "limit_mode": "device", "device_id": "canonical-device-1",
    ]))
}

final class ImportFlowTests: XCTestCase {

    /// 完整链路：verify → ticket → exchange，并且**总是**尝试 ticket，
    /// 因为 device_token 是遥测的唯一来源。
    func testImportAlwaysPrefersTicketEvenInCompatibilityMode() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http, protected: false)   // 注意：非保护模式
        let client = makeClient(http)

        let outcome = try await client.importAccessCode("122345")

        guard case let .managed(activation) = outcome else {
            return XCTFail("兼容模式下也应该走 ticket 链路，实际拿到 \(outcome)")
        }
        XCTAssertEqual(activation.deviceToken, "DEVTOKEN-XYZ")
        XCTAssertEqual(activation.subscriptionURL.absoluteString,
                       "https://api.sxnn.de:5443/managed-sub/MANAGED-TOKEN")
        // 后端可能归一化 client_id，要以它返回的为准。
        XCTAssertEqual(activation.deviceID, "canonical-device-1")
        let reported = await client.canReportTelemetry
        XCTAssertTrue(reported)
    }

    /// ticket 是从 launch_url 的路径末段取出来的——后端没有独立的 ticket 字段。
    func testTicketIsExtractedFromLaunchURL() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http)
        _ = try await makeClient(http).importAccessCode("122345")

        let request = http.request(forPath: "/api/import/exchange")
        let body = try XCTUnwrap(request?.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["ticket"] as? String, "TICKET-ABC")
        XCTAssertEqual(json["platform"] as? String, "ios")
    }

    /// `target=shenxianyun` 是官方客户端的兼容协议键，改品牌时不能动它。
    func testTicketRequestCarriesOfficialTarget() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http)
        _ = try await makeClient(http).importAccessCode("122345")

        let body = try XCTUnwrap(http.request(forPath: "/api/import/ticket")?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["target"] as? String, "shenxianyun")
    }

    /// 兼容模式下 ticket 失败可以降级成普通订阅，但必须是 `/sub/`，不是 `/singbox/`。
    func testFallsBackToPlainSubscriptionWhenTicketUnavailable() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http, protected: false)
        http.stub("/api/import/ticket", .init(status: 403, json: [
            "ok": false, "message": "无法创建导入票据",
        ]))
        let client = makeClient(http)

        let outcome = try await client.importAccessCode("122345")

        guard case let .plain(url, status) = outcome else {
            return XCTFail("应降级为普通订阅，实际 \(outcome)")
        }
        XCTAssertEqual(url.absoluteString, "https://api.sxnn.de:5443/sub/122345")
        XCTAssertFalse(url.absoluteString.contains("singbox"))
        XCTAssertEqual(status.expireTime, "2026-12-31 23:59:59")
        let reported = await client.canReportTelemetry
        XCTAssertFalse(reported, "没有 device_token 就不该声称能上报")
    }

    /// **全保护模式下不能降级**：普通订阅会被后端 426 拒绝，
    /// 静默降级只会让用户看到一个连不上的配置，必须把真实原因抛出去。
    func testProtectedModeDoesNotFallBack() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http, protected: true)
        http.stub("/api/import/ticket", .init(status: 403, json: [
            "ok": false, "message": "无法创建导入票据",
        ]))

        do {
            _ = try await makeClient(http).importAccessCode("122345")
            XCTFail("全保护模式下应该抛错，而不是降级")
        } catch let error as ShenxianyunError {
            XCTAssertEqual(error.userMessage, "无法创建导入票据")
        }
    }

    /// 后端把官方导入关掉时要给出可读原因，而不是笼统的失败。
    func testOfficialImportDisabledIsReported() async throws {
        let http = StubHTTPClient()
        stubHappyPath(http)
        http.stub("/api/verify", .init(json: [
            "success": true, "expire_time": "2026-12-31 23:59:59",
            "protected_mode": false,
            "imports": ["shenxianyun": false],
        ]))

        do {
            _ = try await makeClient(http).importAccessCode("122345")
            XCTFail("官方导入关闭时应当报错")
        } catch let error as ShenxianyunError {
            XCTAssertTrue(error.userMessage.contains("未开放"))
        }
    }

    /// HTTP 200 不代表成功：后端有些分支返回 200 + success:false，
    /// 且 message 本身就是给用户看的中文，要原样带出来。
    func testInvalidCodeSurfacesServerMessage() async throws {
        let http = StubHTTPClient()
        http.stub("/api/endpoints", .init(json: StubHTTPClient.productionEndpointsJSON))
        http.stub("/api/verify", .init(json: ["success": false, "message": "无效的提取码"]))

        do {
            _ = try await makeClient(http).importAccessCode("bad")
            XCTFail("无效提取码应当抛错")
        } catch let error as ShenxianyunError {
            XCTAssertEqual(error.userMessage, "无效的提取码")
        }
    }
}
