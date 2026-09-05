import Foundation
import XCTest
@testable import ShenxianyunKit

final class EndpointsTests: XCTestCase {
    /// 用生产实测的响应形状解码，防止字段名写错却一直没人发现。
    func testDecodesProductionShape() throws {
        let data = try JSONSerialization.data(
            withJSONObject: StubHTTPClient.productionEndpointsJSON)
        let endpoints = try JSONDecoder().decode(ShenxianyunEndpoints.self, from: data)

        XCTAssertEqual(endpoints.apiBases.map(\.absoluteString),
                       ["https://api.sxnn.de:5443", "https://sxnn.de"])
        XCTAssertEqual(endpoints.subBase.absoluteString, "https://api.sxnn.de:5443")
        XCTAssertEqual(endpoints.downloadBase?.absoluteString, "https://sxy.sxnn.de:5443")
        XCTAssertEqual(endpoints.directPorts, [5443])
        XCTAssertEqual(endpoints.directDNSDomains, ["+.sxnn.de"])
        XCTAssertTrue(endpoints.directDNSAuto)
        XCTAssertEqual(endpoints.version, 1)
        XCTAssertFalse(endpoints.isBootstrapOnly)
    }

    /// 后端对未配置项返回**空字符串**而不是省略键，空串必须当成"没有"。
    func testEmptyStringsBecomeNil() throws {
        var json = StubHTTPClient.productionEndpointsJSON
        json["download_base"] = ""
        json["bootstrap_proxy"] = ""
        let data = try JSONSerialization.data(withJSONObject: json)
        let endpoints = try JSONDecoder().decode(ShenxianyunEndpoints.self, from: data)

        XCTAssertNil(endpoints.downloadBase)
        XCTAssertNil(endpoints.bootstrapProxy)
    }

    /// 编解码必须对称，否则本地缓存写得进读不出——合成的编码器会把 URL 写成
    /// 另一种形状，正是这里要防的。
    func testRoundTripsThroughCache() throws {
        let data = try JSONSerialization.data(
            withJSONObject: StubHTTPClient.productionEndpointsJSON)
        let original = try JSONDecoder().decode(ShenxianyunEndpoints.self, from: data)

        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ShenxianyunEndpoints.self, from: encoded)

        XCTAssertEqual(original, restored)
    }

    func testMissingSubBaseIsRejected() throws {
        var json = StubHTTPClient.productionEndpointsJSON
        json["sub_base"] = ""
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(ShenxianyunEndpoints.self, from: data))
    }
}
