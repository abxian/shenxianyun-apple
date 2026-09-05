import Foundation

/// 激活成功后拿到的一整套凭据（契约 D）。
///
/// **关键：`deviceToken` 就是遥测接口的 Bearer 凭据。**
/// `/api/v2/client/heartbeat|traffic|offline` 全部要求
/// `Authorization: Bearer <device_token>`，而这个 token 只能从
/// `/api/import/exchange` 拿到。所以「受保护导入」和「心跳上报」不是两件事，
/// 是同一条链——没走过 ticket 就没有遥测能力。
public struct ShenxianyunActivation: Codable, Equatable, Sendable {
    /// 提取码（后端字段叫 name）。
    public let code: String
    public let expiresAt: String
    /// 遥测用的 Bearer 凭据。**属于机密，只写钥匙串或 App Group 私有区，不进日志。**
    public let deviceToken: String
    /// 受管订阅地址 `/managed-sub/<token>`。Hako 直接拉它，内容是 Clash 原文。
    public let subscriptionURL: URL
    /// 后端归一化后的设备 id，可能与我们提交的 client_id 不同，**以后端返回的为准**。
    public let deviceID: String
    public let limitMode: String?

    public init(
        code: String, expiresAt: String, deviceToken: String,
        subscriptionURL: URL, deviceID: String, limitMode: String?
    ) {
        self.code = code
        self.expiresAt = expiresAt
        self.deviceToken = deviceToken
        self.subscriptionURL = subscriptionURL
        self.deviceID = deviceID
        self.limitMode = limitMode
    }
}

extension APITransport {
    /// 第一步：`POST /api/import/ticket`，`{code, target:"shenxianyun"}`。
    ///
    /// `target=shenxianyun` 是**官方客户端的兼容协议键，不是展示品牌**，改品牌时不能动它。
    ///
    /// 返回体里没有独立的 ticket 字段，票据藏在 `launch_url` 的路径末段
    /// （`/import/launch/<token>`），要自己取出来。后端限流 12 次 / 60 秒。
    func issueImportTicket(code: String, bases: [URL]) async throws -> String {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/import/ticket", method: "POST",
            body: ["code": code, "target": "shenxianyun"])
        let json = try decodeEnvelope(response)
        guard let launch = json["launch_url"] as? String,
              let ticket = launch.split(separator: "/").last.map(String.init),
              !ticket.isEmpty
        else {
            throw ShenxianyunError.invalidResponse("ticket 响应里没有可用的 launch_url")
        }
        return ticket
    }

    /// 第二步：`POST /api/import/exchange`，换设备凭据与受管订阅地址。
    ///
    /// 票据**一次性**：后端用 `UPDATE ... WHERE consumed_at IS NULL` 保证只能兑换一次，
    /// 重复兑换返回 410。所以失败重试必须**从第一步重新申请票据**，不能重放同一张。
    /// 后端限流 20 次 / 60 秒。
    func exchangeImportTicket(
        ticket: String, clientID: String, platform: String, bases: [URL]
    ) async throws -> ShenxianyunActivation {
        let response = try await sendWithFailover(
            bases: bases, path: "/api/import/exchange", method: "POST",
            body: ["ticket": ticket, "client_id": clientID, "platform": platform])
        let json = try decodeEnvelope(response)
        guard let token = json["device_token"] as? String, !token.isEmpty,
              let subRaw = json["subscription_url"] as? String,
              let subURL = URL(string: subRaw)
        else {
            throw ShenxianyunError.invalidResponse("exchange 响应缺少 device_token 或 subscription_url")
        }
        return ShenxianyunActivation(
            code: json["name"] as? String ?? "",
            expiresAt: json["expires_at"] as? String ?? "",
            deviceToken: token,
            subscriptionURL: subURL,
            // 后端可能把 client_id 归一化过，以它返回的为准。
            deviceID: json["device_id"] as? String ?? clientID,
            limitMode: json["limit_mode"] as? String
        )
    }
}
