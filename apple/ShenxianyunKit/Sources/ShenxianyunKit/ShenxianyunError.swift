import Foundation

/// 后端返回的业务错误。后端统一用 `{"ok": false, "message": "..."}`（少数接口用 `success`），
/// 且**错误文案本身就是给用户看的中文**，所以这里原样带出来，不要再翻译一遍。
public struct ShenxianyunServerError: Error, Equatable, Sendable {
    public let statusCode: Int
    /// 后端给的中文文案。为空时调用方用自己的兜底文案。
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    /// 提取码在保护模式下必须走 ticket 链路。后端用 426 表示「该走受管订阅了」。
    public var requiresManagedSubscription: Bool { statusCode == 426 }
    /// 票据过期或已被用掉。
    public var ticketExpired: Bool { statusCode == 410 }
    /// 设备凭据无效——需要重新激活。
    public var deviceCredentialInvalid: Bool { statusCode == 401 }
}

public enum ShenxianyunError: Error, Sendable {
    /// 所有 API 地址都试过了，全部失败。带上最后一个失败原因。
    case allEndpointsFailed(underlying: Error)
    case server(ShenxianyunServerError)
    case invalidResponse(String)
    /// 被后端限流，且给了 Retry-After。
    case rateLimited(retryAfter: TimeInterval)
    /// 还没激活过，没有设备凭据。
    case notActivated

    public var userMessage: String {
        switch self {
        case let .server(error) where !error.message.isEmpty:
            return error.message
        case .server:
            return "服务器返回了错误，请稍后重试"
        case .allEndpointsFailed:
            return "连不上服务器，请检查网络后重试"
        case .invalidResponse:
            return "服务器响应异常，请稍后重试"
        case .rateLimited:
            return "操作过于频繁，请稍后重试"
        case .notActivated:
            return "请先输入提取码完成导入"
        }
    }
}

extension ShenxianyunError: Equatable {
    public static func == (lhs: ShenxianyunError, rhs: ShenxianyunError) -> Bool {
        switch (lhs, rhs) {
        case let (.server(a), .server(b)): return a == b
        case let (.invalidResponse(a), .invalidResponse(b)): return a == b
        case let (.rateLimited(a), .rateLimited(b)): return a == b
        case (.notActivated, .notActivated): return true
        case (.allEndpointsFailed, .allEndpointsFailed): return true
        default: return false
        }
    }
}
