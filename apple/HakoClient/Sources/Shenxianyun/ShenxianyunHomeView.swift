import ShenxianyunKit
import SwiftUI

/// 神仙云主界面。信息架构逐项对齐安卓 `design_main.xml`：
/// 标志 → 应用名 → 副标题 → 线路 → 电源键 → 状态行 → 模式切换 → 五个大按钮。
///
/// 安卓上「外部资源」「日志」两项是 `visibility=GONE`，这里同样不放。
struct ShenxianyunHomeView: View {
    @ObservedObject var vpn: VPNController
    @ObservedObject var profiles: ProfilesViewModel
    @ObservedObject var command: ClashCommandClient
    let client: ShenxianyunClient
    /// 进入上游那套完整界面（节点选择、设置都在里面）。
    let openUpstream: () -> Void

    @State private var showsImport = false
    @State private var isWorking = false
    @State private var notice: String?
    @State private var accessCode: String?
    @State private var expiresAt: String?

    private var isConnected: Bool { vpn.status == "connected" }
    private var isTransitioning: Bool {
        vpn.status == "connecting" || vpn.status == "disconnecting"
    }

    private var statusText: String {
        switch vpn.status {
        case "connected": return "运行中"
        case "connecting": return "连接中"
        case "disconnecting": return "断开中"
        default: return "已停止"
        }
    }

    var body: some View {
        ZStack {
            SXYTheme.canvas
            ScrollView {
                VStack(spacing: 0) {
                    header
                    SXYPowerButton(
                        isOn: isConnected,
                        isBusy: isTransitioning || isWorking,
                        action: togglePower)
                        .padding(.top, 18)

                    Text(isConnected ? "已连接" : "点此启动")
                        .font(.system(size: 13))
                        .foregroundStyle(SXYTheme.textMuted)
                        .padding(.top, 14)

                    statusRow.padding(.top, 10)

                    if let notice {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(SXYTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }

                    SXYModePicker(
                        mode: command.mode,
                        isEnabled: command.isConnected,
                        select: setMode)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)

                    actions.padding(.horizontal, 20).padding(.top, 16)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showsImport) {
            ShenxianyunImportView(client: client, onImported: handleImported)
                .shenxianyunLight()
        }
        .task { await loadState() }
        .shenxianyunLight()
    }

    // MARK: - 分块

    private var header: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SXYTheme.powerFill)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white))
                .padding(.bottom, 8)

            Text(ShenxianyunProfile.appName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(SXYTheme.textSoft)
            Text("智能加速 · 稳定连接")
                .font(.system(size: 12))
                .foregroundStyle(SXYTheme.textMuted)
        }
        .padding(.top, 24)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .foregroundStyle(isConnected ? SXYTheme.green : SXYTheme.textMuted)
            Text("·").foregroundStyle(SXYTheme.chevron)
            Text(accessCode == nil ? "未选择" : "提取码已绑定")
                .foregroundStyle(SXYTheme.textMuted)
            if let expiresAt, !expiresAt.isEmpty {
                Text("·").foregroundStyle(SXYTheme.chevron)
                Text("到期 \(expiresAt.prefix(10))")
                    .foregroundStyle(SXYTheme.textMuted)
            }
        }
        .font(.system(size: 12))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            SXYActionRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "选择节点", trailing: .chevron, action: openUpstream)

            SXYActionRow(
                icon: "key.fill",
                title: accessCode == nil ? "提取码订阅" : "切换提取码",
                subtitle: "输入或切换本机使用的提取码",
                trailing: .chevron) { showsImport = true }

            SXYActionRow(
                icon: "arrow.clockwise",
                title: "更新节点",
                subtitle: "刷新当前提取码的节点信息",
                isBusy: isWorking, action: updateNodes)

            // 购买入口受 profile 开关控制。App Store 审核指南 3.1.3(f) 禁止
            // 「calls to action for purchase outside of the app」，跳转支付页正属此类，
            // 上架时必须关掉。用户从网站买好提取码后直接回来输入即可。
            if ShenxianyunProfile.paymentEntryEnabled {
                SXYActionRow(
                    icon: "creditcard.fill",
                    title: accessCode == nil ? "新购提取码" : "续费提取码",
                    subtitle: accessCode == nil ? "打开购买页面获取提取码" : "在官网延长当前提取码",
                    trailing: .external, action: openPayment)
            }

            SXYActionRow(
                icon: "gearshape.fill",
                title: "设置", trailing: .chevron, action: openUpstream)
        }
    }

    // MARK: - 动作

    private func loadState() async {
        accessCode = await client.savedAccessCode()
        expiresAt = await client.savedActivation()?.expiresAt
        // 地址表刷新是纯优化，失败也不提示——用户不需要知道。
        await client.refreshEndpoints()
    }

    private func togglePower() {
        Task {
            notice = nil
            if isConnected {
                await vpn.stop()
            } else {
                guard await client.activeSubscriptionURL() != nil else {
                    notice = "请先用提取码导入订阅"
                    showsImport = true
                    return
                }
                _ = await vpn.start()
            }
        }
    }

    private func handleImported(_ subscriptionURL: URL) {
        Task {
            isWorking = true
            defer { isWorking = false }
            // 复用上游的订阅安装：它会建配置、拉内容、校验并落盘。
            profiles.installSubscription(subscriptionURL.absoluteString)
            accessCode = await client.savedAccessCode()
            expiresAt = await client.savedActivation()?.expiresAt
            notice = "订阅已导入，可以启动了"
        }
    }

    private func updateNodes() {
        Task {
            isWorking = true
            defer { isWorking = false }
            guard let url = await client.activeSubscriptionURL() else {
                notice = "请先用提取码导入订阅"
                return
            }
            profiles.installSubscription(url.absoluteString)
            notice = "已请求更新节点"
        }
    }

    /// 模式切换直接下到内核。失败时把原因显示出来——静默失败会让用户
    /// 以为切过去了，实际流量还走着旧模式。
    private func setMode(_ mode: String) {
        guard command.mode.lowercased() != mode else { return }
        Task {
            let ok = await command.setMode(mode)
            if !ok {
                notice = command.lastError.isEmpty
                    ? "模式切换失败，请稍后重试" : command.lastError
            } else {
                notice = nil
            }
        }
    }

    private func openPayment() {
        Task {
            let url = await (accessCode == nil
                ? client.purchaseURL() : client.renewURL())
            await UIApplication.shared.open(url)
        }
    }
}
