import ShenxianyunKit
import SwiftUI

/// 提取码导入。用户只需要输入提取码，其余（校验、ticket、受管订阅）全在后台完成。
struct ShenxianyunImportView: View {
    let client: ShenxianyunClient
    let onImported: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            SXYTheme.canvas
            VStack(spacing: 18) {
                Capsule()
                    .fill(SXYTheme.chevron.opacity(0.5))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)

                Text("输入提取码")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(SXYTheme.textSoft)
                Text("输入神仙云提取码，自动导入订阅并设为当前配置。")
                    .font(.system(size: 13))
                    .foregroundStyle(SXYTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                TextField("提取码", text: $code)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SXYTheme.textSoft)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SXYTheme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(SXYTheme.surfaceStrokeSoft, lineWidth: 1))
                    .padding(.horizontal, 24)

                // 错误文案直接用后端返回的中文——它本来就是写给用户看的。
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0xC0392B))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().controlSize(.small).tint(.white) }
                        Text(isWorking ? "导入中…" : "导入订阅")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SXYTheme.powerFill))
                    .opacity(trimmed.isEmpty || isWorking ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || isWorking)
                .padding(.horizontal, 24)

                Button("没有提取码？去购买") {
                    Task { await UIApplication.shared.open(client.purchaseURL()) }
                }
                .font(.system(size: 13))
                .foregroundStyle(SXYTheme.purple)

                Spacer(minLength: 0)
            }
            .padding(.bottom, 24)
        }
        .task {
            code = await client.savedAccessCode() ?? ""
            focused = code.isEmpty
        }
        .shenxianyunLight()
    }

    private func submit() {
        let value = trimmed
        guard !value.isEmpty, !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                let outcome = try await client.importAccessCode(value)
                onImported(outcome.subscriptionURL)
                dismiss()
            } catch let error as ShenxianyunError {
                errorText = error.userMessage
            } catch {
                errorText = "导入失败，请检查网络后重试"
            }
        }
    }
}
