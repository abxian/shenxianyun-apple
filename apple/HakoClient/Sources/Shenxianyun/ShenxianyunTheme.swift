import SwiftUI

/// 神仙云配色，逐值移植自安卓客户端，两端观感一致。
///
/// 来源：`shenxianyun-android/design/src/main/res/values/colors.xml` 与
/// `drawable/bg_sxy_*.xml`。安卓用 ARGB（`#AARRGGBB`），这里拆成 RGB + 不透明度。
///
/// **这套是纯浅色的，全局锁 light。**族内有前车之鉴：PC 版曾因为首页固定浅色、
/// 而系统深色模式下 MUI 菜单与弹窗仍继承深色主题白字，造成浅底白字几乎不可见
/// （2026-07-29 v2.5.33 修复）。所以这里凡是会新开一层的地方
/// —— sheet、alert、confirmationDialog、menu —— 都必须显式带 `.shenxianyunLight()`，
/// 不能只在根视图标一次就以为万事大吉。
enum SXYTheme {

    // MARK: - 背景

    static let bgTop = Color(hex: 0xF8F2FF)
    static let bgCenter = Color(hex: 0xF5F5FF)
    static let bgBottom = Color(hex: 0xEAF2FF)

    /// 左上角青紫光晕（安卓 250dp 圆，半径 160dp，透明度 0x42）。
    static let glowTopLeading = Color(hex: 0xE6C7FF)
    /// 右下角蓝光晕（安卓 300dp 圆，半径 190dp，透明度 0x40）。
    static let glowBottomTrailing = Color(hex: 0x77A7FF)

    // MARK: - 表面

    static let surface = Color(hex: 0xFFFFFF).opacity(0xD9 / 255)
    static let surfaceSoft = Color(hex: 0xFFFFFF).opacity(0xC9 / 255)
    static let surfaceSoftEnd = Color(hex: 0xEFF5FF).opacity(0xBF / 255)
    static let surfaceStrokeSoft = Color(hex: 0xC8CBF5).opacity(0x88 / 255)

    static let iconTileStart = Color(hex: 0xFFFFFF).opacity(0xE8 / 255)
    static let iconTileEnd = Color(hex: 0xECF1FF).opacity(0xC9 / 255)
    static let iconTileStroke = Color(hex: 0xFFFFFF).opacity(0xF2 / 255)

    // MARK: - 文字与图标

    static let textSoft = Color(hex: 0x172566)
    static let textMuted = Color(hex: 0x827EAE)
    static let iconTint = Color(hex: 0x714CF4)
    static let chevron = Color(hex: 0x9CA7D5)

    // MARK: - 强调色

    static let cyan = Color(hex: 0x25D9E9)
    static let green = Color(hex: 0x14A97B)
    static let purple = Color(hex: 0x7549F6)
    static let blue = Color(hex: 0x4F76FF)
    static let powerPink = Color(hex: 0xA84EFF)

    // MARK: - 组合

    /// 主背景：315° 线性渐变 + 两团径向光晕。
    static var canvas: some View {
        ZStack {
            LinearGradient(
                colors: [bgTop, bgCenter, bgBottom],
                startPoint: .topTrailing, endPoint: .bottomLeading)
            GeometryReader { geometry in
                RadialGradient(
                    colors: [glowTopLeading.opacity(0x42 / 255), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 190)
                    .frame(width: 250, height: 250)
                RadialGradient(
                    colors: [glowBottomTrailing.opacity(0x40 / 255), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 220)
                    .frame(width: 300, height: 300)
                    .position(x: geometry.size.width - 150,
                              y: geometry.size.height - 150)
            }
        }
        .ignoresSafeArea()
    }

    /// 电源键内圈：粉 → 紫 → 青，315°。
    static let powerFill = LinearGradient(
        colors: [powerPink, Color(hex: 0x7A68FF), cyan],
        startPoint: .topTrailing, endPoint: .bottomLeading)

    /// 大按钮卡片底。
    static let actionFill = LinearGradient(
        colors: [surfaceSoft, surfaceSoftEnd],
        startPoint: .top, endPoint: .bottom)

    static let iconTileFill = LinearGradient(
        colors: [iconTileStart, iconTileEnd],
        startPoint: .top, endPoint: .bottom)
}

extension Color {
    /// 从 `0xRRGGBB` 构造。安卓那边是 ARGB，移植时把 alpha 拆出来单独用 `.opacity`。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

extension View {
    /// 锁浅色。**每一层新弹出的界面都要单独带上**——见 SXYTheme 的说明。
    func shenxianyunLight() -> some View {
        preferredColorScheme(.light)
            .environment(\.colorScheme, .light)
            .tint(SXYTheme.purple)
    }
}
