import Foundation

/// 后端下发的地址与线路（契约 A）。
///
/// **客户端只内置一个引导地址**，其余一律以本接口为准——后台改「地址/线路」即刻全网生效，
/// 不需要发新版。旧 sing-box 线把地址硬编码在代码里，域名一换就整条线作废，别重蹈。
///
/// 字段与后端 `build_endpoints_payload()` 一一对应（vpn-web `master/app.py`）。
public struct ShenxianyunEndpoints: Codable, Equatable, Sendable {
    /// API 地址，**按顺序故障转移**，前面的优先。
    public let apiBases: [URL]
    /// 订阅地址的基址。注意它与 `apiBases[0]` 未必相同。
    public let subBase: URL
    /// 安装包/资源下载站。可能为空字符串（后台未配置）。
    public let downloadBase: URL?
    /// 需要直连的端口。用于订阅里生成 `DST-PORT,<port>,DIRECT`。
    public let directPorts: [Int]
    public let directDNSDomains: [String]
    public let directDNSNameservers: [String]
    public let directDNSAuto: Bool
    /// 兜底 HTTP 代理：直连与系统代理都连不上 web 时，经它去连 API。
    /// 只需能连到 API 服务器，不必翻墙。后台未配置时为 nil。
    public let bootstrapProxy: String?
    public let updatedAt: String?
    public let version: Int

    private enum CodingKeys: String, CodingKey {
        case apiBases = "api_bases"
        case subBase = "sub_base"
        case downloadBase = "download_base"
        case directPorts = "direct_ports"
        case directDNSDomains = "direct_dns_domains"
        case directDNSNameservers = "direct_dns_nameservers"
        case directDNSAuto = "direct_dns_auto"
        case bootstrapProxy = "bootstrap_proxy"
        case updatedAt = "updated_at"
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 后端对未配置项返回空字符串而不是省略键，所以空串一律当成"没有"。
        func url(_ raw: String?) -> URL? {
            guard let raw, !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        let rawBases = try container.decodeIfPresent([String].self, forKey: .apiBases) ?? []
        apiBases = rawBases.compactMap(url)
        guard let sub = url(try container.decodeIfPresent(String.self, forKey: .subBase)) else {
            throw ShenxianyunError.invalidResponse("endpoints 缺少可用的 sub_base")
        }
        subBase = sub
        downloadBase = url(try container.decodeIfPresent(String.self, forKey: .downloadBase))
        directPorts = try container.decodeIfPresent([Int].self, forKey: .directPorts) ?? []
        directDNSDomains = try container.decodeIfPresent([String].self, forKey: .directDNSDomains) ?? []
        directDNSNameservers = try container.decodeIfPresent([String].self, forKey: .directDNSNameservers) ?? []
        directDNSAuto = try container.decodeIfPresent(Bool.self, forKey: .directDNSAuto) ?? false
        let proxy = try container.decodeIfPresent(String.self, forKey: .bootstrapProxy) ?? ""
        bootstrapProxy = proxy.isEmpty ? nil : proxy
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    /// 必须手写，且必须与 `init(from:)` 对称：解码把地址当**字符串**读，
    /// 合成的编码器却会按 `URL` 写，两者不一致会让本地缓存无法回读。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiBases.map(\.absoluteString), forKey: .apiBases)
        try container.encode(subBase.absoluteString, forKey: .subBase)
        try container.encode(downloadBase?.absoluteString ?? "", forKey: .downloadBase)
        try container.encode(directPorts, forKey: .directPorts)
        try container.encode(directDNSDomains, forKey: .directDNSDomains)
        try container.encode(directDNSNameservers, forKey: .directDNSNameservers)
        try container.encode(directDNSAuto, forKey: .directDNSAuto)
        try container.encode(bootstrapProxy ?? "", forKey: .bootstrapProxy)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(version, forKey: .version)
    }

    public init(
        apiBases: [URL], subBase: URL, downloadBase: URL? = nil,
        directPorts: [Int] = [], directDNSDomains: [String] = [],
        directDNSNameservers: [String] = [], directDNSAuto: Bool = false,
        bootstrapProxy: String? = nil, updatedAt: String? = nil, version: Int = 1
    ) {
        self.apiBases = apiBases
        self.subBase = subBase
        self.downloadBase = downloadBase
        self.directPorts = directPorts
        self.directDNSDomains = directDNSDomains
        self.directDNSNameservers = directDNSNameservers
        self.directDNSAuto = directDNSAuto
        self.bootstrapProxy = bootstrapProxy
        self.updatedAt = updatedAt
        self.version = version
    }

    /// 只有引导地址可用时的兜底。真正的地址表拿到之前，先用它把 `/api/endpoints` 请下来。
    public static func bootstrap(_ base: URL) -> ShenxianyunEndpoints {
        ShenxianyunEndpoints(apiBases: [base], subBase: base, version: 0)
    }

    /// 这份地址表是不是仅有引导值（还没真正发现过）。
    public var isBootstrapOnly: Bool { version == 0 }
}
