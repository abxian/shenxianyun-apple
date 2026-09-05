import SwiftUI

/// 大按钮，对应安卓的 `LargeActionLabel` + `bg_sxy_action` 背景。
/// 图标装在圆角方块里（`bg_sxy_icon_tile`），右侧 chevron 只在会进入子页面时显示。
struct SXYActionRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    /// 进入子页面显示 chevron；跳外部链接显示外链图标；就地执行的动作不显示尾图标。
    var trailing: Trailing = .none
    var isBusy = false
    let action: () -> Void

    enum Trailing { case none, chevron, external }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SXYTheme.iconTileFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SXYTheme.iconTileStroke, lineWidth: 1))
                    if isBusy {
                        ProgressView().controlSize(.small).tint(SXYTheme.iconTint)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(SXYTheme.iconTint)
                    }
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SXYTheme.textSoft)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(SXYTheme.textMuted)
                    }
                }
                Spacer(minLength: 8)

                switch trailing {
                case .none:
                    EmptyView()
                case .chevron:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SXYTheme.chevron)
                case .external:
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SXYTheme.chevron)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SXYTheme.actionFill))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SXYTheme.surfaceStrokeSoft, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

/// 电源键：外圈光晕 + 内圈渐变实心圆。对应安卓的 `power_halo` + `power_button`。
struct SXYPowerButton: View {
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(hex: 0x9C72FF).opacity(0x3A / 255), .clear],
                        center: .center, startRadius: 40, endRadius: 96))
                    .frame(width: 192, height: 192)
                Circle()
                    .stroke(Color(hex: 0x7B57FF).opacity(0x88 / 255), lineWidth: 2)
                    .frame(width: 168, height: 168)

                // 安卓那边 bg_sxy_power_inner 是常驻彩色渐变，停止态也不去饱和，
                // 只有图标与文字变。这里保持一致，不自作主张加灰态。
                Circle()
                    .fill(SXYTheme.powerFill)
                    .frame(width: 148, height: 148)
                    .overlay(Circle().stroke(
                        Color.white.opacity(0xCC / 255), lineWidth: 2))

                VStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: isOn ? "stop.fill" : "power")
                            .font(.system(size: 40, weight: .bold))
                        Text(isOn ? "停止" : "启动")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }
}

/// 规则 / 全局模式切换，对应安卓的 `MaterialButtonToggleGroup`。
///
/// 选中态直接反映**内核当前的 mode**，不维护本地状态：模式是内核的事实，
/// 本地存一份只会在切换失败或外部改动时和内核不一致。
/// 隧道没起来时 Clash API 不可用，此时禁用交互而不是让用户点了没反应。
struct SXYModePicker: View {
    /// 内核当前模式：`rule` / `global` / `direct`；未连接时上游给的是 `—`。
    let mode: String
    let isEnabled: Bool
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "规则模式", id: "rule")
            segment(title: "全局模式", id: "global")
        }
        .padding(3)
        .background(Capsule().fill(SXYTheme.surfaceSoft))
        .overlay(Capsule().stroke(SXYTheme.surfaceStrokeSoft, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.55)
        .allowsHitTesting(isEnabled)
    }

    private func segment(title: String, id: String) -> some View {
        let selected = mode.lowercased() == id
        return Button { select(id) } label: {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : SXYTheme.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(selected
                        ? AnyShapeStyle(SXYTheme.powerFill)
                        : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
    }
}
