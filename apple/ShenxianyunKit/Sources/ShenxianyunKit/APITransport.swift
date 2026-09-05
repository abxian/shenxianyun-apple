import Foundation

/// 注入点：测试里换成假实现，就不必碰 URLProtocol，也不会真发网络请求。
public protocol ShenxianyunHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ShenxianyunHTTPClient {}

/// 一次 HTTP 往返的结果，业务层只关心这三样。
struct RawResponse: Sendable {
    let status: Int
    let body: Data
    let retryAfter: TimeInterval?
}

/// 负责：拼 URL、带鉴权头、**按 api_bases 顺序故障转移**、解析后端的统一响应壳。
///
/// 后端的响应壳有两种写法：多数接口用 `{"ok": bool, "message": str}`，
/// `/api/verify` 历史原因用 `{"success": bool, "message": str}`。两种都要认。
struct APITransport: Sendable {
    let http: ShenxianyunHTTPClient
    /// 后端限流较紧（ticket 12/60s、verify 15/60s、exchange 20/60s），超时给短一点更快失败转移。
    let timeout: TimeInterval

    init(http: ShenxianyunHTTPClient, timeout: TimeInterval = 15) {
        self.http = http
        self.timeout = timeout
    }

    // MARK: - 单个地址

    func send(
        base: URL, path: String, method: String = "GET",
        body: [String: Any]? = nil, deviceToken: String? = nil
    ) async throws -> RawResponse {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw ShenxianyunError.invalidResponse("无法拼接 URL：\(base) + \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceToken {
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShenxianyunError.invalidResponse("非 HTTP 响应")
        }
        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return RawResponse(status: http.statusCode, body: data, retryAfter: retryAfter)
    }

    // MARK: - 多地址故障转移

    /// 依次尝试每个 base，直到某个返回了 **HTTP 响应**（哪怕是 4xx/5xx）。
    ///
    /// 只有传输层错误（连不上、超时、TLS 失败）才继续换下一个地址；
    /// 服务器明确回了业务错误说明这台是通的，换地址没有意义，直接抛出去。
    func sendWithFailover(
        bases: [URL], path: String, method: String = "GET",
        body: [String: Any]? = nil, deviceToken: String? = nil
    ) async throws -> RawResponse {
        guard !bases.isEmpty else {
            throw ShenxianyunError.invalidResponse("没有可用的 API 地址")
        }
        var lastError: Error = ShenxianyunError.invalidResponse("没有可用的 API 地址")
        for base in bases {
            do {
                return try await send(
                    base: base, path: path, method: method, body: body, deviceToken: deviceToken)
            } catch let error as ShenxianyunError {
                throw error       // 拼 URL 之类的自身问题，换地址也没用
            } catch {
                lastError = error // 传输层失败，试下一个
            }
        }
        throw ShenxianyunError.allEndpointsFailed(underlying: lastError)
    }

    // MARK: - 响应壳

    /// 解出 JSON 字典，并把后端的失败壳翻译成 `ShenxianyunError`。
    ///
    /// 注意 HTTP 200 不代表成功：后端有些分支是 200 + `{"success": false}`。
    func decodeEnvelope(_ response: RawResponse) throws -> [String: Any] {
        if response.status == 429 {
            throw ShenxianyunError.rateLimited(retryAfter: response.retryAfter ?? 60)
        }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let message = (json?["message"] as? String) ?? ""

        guard let json else {
            // 后端在少数路径上直接返回纯文本（如 /sub 的 "invalid or expired code"）。
            let text = String(data: response.body, encoding: .utf8) ?? ""
            throw ShenxianyunError.server(
                ShenxianyunServerError(statusCode: response.status, message: text))
        }
        // `ok` 与 `success` 是同一语义的两种历史写法。
        let succeeded = (json["ok"] as? Bool) ?? (json["success"] as? Bool) ?? false
        guard (200..<300).contains(response.status), succeeded else {
            throw ShenxianyunError.server(
                ShenxianyunServerError(statusCode: response.status, message: message))
        }
        return json
    }
}
