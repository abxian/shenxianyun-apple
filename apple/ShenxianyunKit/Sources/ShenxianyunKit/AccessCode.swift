import Foundation

/// 提取码校验结果（契约 B）。
///
/// **旧 sing-box 线只读了 `ok` 一个字段**，把 `protected_mode`、`expire_time`、`imports`
/// 全丢了。后果很实在：全保护一开，旧线只会显示"提取码无效或已过期"，
/// 用户完全不知道发生了什么。这里五个字段都要接住。
public struct AccessCodeStatus: Equatable, Sendable {
    public let code: String
    /// 到期时间，首页要显示。后端给的是 `YYYY-MM-DD HH:MM:SS` 字符串。
    public let expireTime: String
    /// 全保护模式。为 true 时**必须**走 ticket 链路，直接拉 `/sub/<code>` 会被 426 拒绝。
    public let isProtected: Bool
    /// 各客户端类型是否开放导入：shenxianyun / shadowrocket / clash。
    public let imports: [String: Bool]
    /// 仅非保护模式下后端才返回真实下载地址；保护模式下为 nil。
    public let downloadPath: String?

    public init(
        code: String, expireTime: String, isProtected: Bool,
        imports: [String: Bool], downloadPath: String?
    ) {
        self.code = code
        self.expireTime = expireTime
        self.isProtected = isProtected
        self.imports = imports
        self.downloadPath = downloadPath
    }

    /// 官方客户端（也就是我们）是否被允许导入。
    public var officialImportEnabled: Bool { imports["shenxianyun"] ?? true }
}

extension APITransport {
    /// `POST /api/verify`，body `{"code": "..."}`。
    ///
    /// 用 POST 而不是旧线那个 `GET /api/verify/<code>`：只有 POST 那版会返回
    /// `protected_mode` / `imports` / `expire_time`。
    ///
    /// 后端限流 15 次 / 60 秒，且**故意 sleep 0.3 秒**防爆破，所以别做快速重试。
    func verify(code: String, bases: [URL]) async throws -> AccessCodeStatus {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/verify", method: "POST", body: ["code": code])
        let json = try decodeEnvelope(response)
        var imports: [String: Bool] = [:]
        if let raw = json["imports"] as? [String: Any] {
            for (key, value) in raw { imports[key] = value as? Bool ?? false }
        }
        return AccessCodeStatus(
            code: code,
            expireTime: json["expire_time"] as? String ?? "",
            isProtected: json["protected_mode"] as? Bool ?? false,
            imports: imports,
            downloadPath: json["url"] as? String
        )
    }
}
