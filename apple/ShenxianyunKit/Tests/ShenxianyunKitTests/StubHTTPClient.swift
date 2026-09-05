import Foundation
@testable import ShenxianyunKit

/// 按「路径 → 响应」查表的假 HTTP 客户端。不碰网络，因此测试可离线跑、可重复。
final class StubHTTPClient: ShenxianyunHTTPClient, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int = 200, json: Any, headers: [String: String] = [:]) {
            self.status = status
            self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            self.headers = headers
        }

        init(status: Int, text: String) {
            self.status = status
            self.body = Data(text.utf8)
            self.headers = [:]
        }
    }

    /// 路径 → 响应。路径用 `URL.path`（不含 host），例如 `/api/verify`。
    private var replies: [String: Reply] = [:]
    /// 这些 host 直接抛传输层错误，用来测故障转移。
    private var failingHosts: Set<String> = []

    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func stub(_ path: String, _ reply: Reply) {
        lock.withLock { replies[path] = reply }
    }

    func failHost(_ host: String) {
        lock.withLock { _ = failingHosts.insert(host) }
    }

    func recordedPaths() -> [String] {
        lock.withLock { requests.compactMap { $0.url?.path } }
    }

    func request(forPath path: String) -> URLRequest? {
        lock.withLock { requests.last { $0.url?.path == path } }
    }

    func recordedHosts() -> [String] {
        lock.withLock { requests.compactMap { $0.url?.host } }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // 必须用 withLock 的作用域写法：NSLock.lock() 在 async 上下文里不可用
        // （挂起点跨越持锁区间会死锁，编译器直接拦下）。
        let (shouldFail, reply) = lock.withLock { () -> (Bool, Reply?) in
            requests.append(request)
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            return (failingHosts.contains(host), replies[path])
        }

        if shouldFail {
            throw URLError(.cannotConnectToHost)
        }
        guard let reply else {
            throw URLError(.unsupportedURL)  // 未 stub 的路径当成传输失败，好定位遗漏
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension StubHTTPClient {
    /// 生产环境 /api/endpoints 的真实响应形状（2026-09-05 实测）。
    static var productionEndpointsJSON: [String: Any] {
        [
            "api_bases": ["https://api.sxnn.de:5443", "https://sxnn.de"],
            "bootstrap_proxy": "",
            "direct_dns_auto": true,
            "direct_dns_domains": ["+.sxnn.de"],
            "direct_dns_nameservers": ["223.5.5.5", "119.29.29.29"],
            "direct_ports": [5443],
            "download_base": "https://sxy.sxnn.de:5443",
            "sub_base": "https://api.sxnn.de:5443",
            "updated_at": "2026-09-05 16:30:23",
            "version": 1,
        ]
    }
}
