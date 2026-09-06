// 由 scripts/brand-apply.py 从根目录 site-profile.properties 生成。
// 不要手改——下次 brand-apply 会覆盖。要改值改 site-profile.properties。
import Foundation

public enum ShenxianyunProfile {
    /// 站点标识，用于区分 sxnn / 52nm 等品牌。
    public static let id = "sxnn"

    /// 展示名。
    public static let appName = "神仙云"

    /// Bundle ID 家族。
    public static let bundleBase = "de.sxnn.shenxianyun"

    /// App Group。**Extension 靠它读设备凭据**，不能用 UserDefaults.standard。
    public static let appGroup = "group.de.sxnn.shenxianyun"

    /// 内置的引导 API 地址。客户端只内置这一个，
    /// 启动后一律以 /api/endpoints 下发的为准；换线路改后台即可，不必发新版。
    public static let bootstrapAPI = URL(string: "https://api.sxnn.de:5443")!

    /// 应用内是否显示购买/续费入口。
    /// App Store 审核指南 3.1.3(f) 禁止「calls to action for purchase outside of the app」，
    /// 上架时必须为 false。默认 false 是刻意的：忘记关会被拒，忘记开只是少个便利入口。
    public static let paymentEntryEnabled = false

    /// 上报给后端的平台标识（exchange 的 platform 字段）。
    public static let platform: String = {
        #if os(tvOS)
            return "tvos"
        #elseif os(macOS)
            return "macos"
        #else
            return "ios"
        #endif
    }()
}
