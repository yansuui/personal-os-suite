import Foundation
import SwiftUI

/// 配对页：服务器地址、配对密钥（SecureField）、设备名、提交与错误提示。
/// 未配对时作为根页面出现；「我的」页可再次进入做重新配对。
struct PairingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverText: String = ""
    @State private var secret: String = ""
    @State private var deviceText: String = ""
    @State private var didPrepare: Bool = false
    @State private var didSubmit: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                header

                if let failure = model.phase.failureMessage {
                    ErrorBanner(message: failure, title: "配对失败")
                } else if let notice = model.notice {
                    ErrorBanner(message: notice, tint: POSTheme.warning)
                }

                fields

                if serverTextIsInvalid {
                    Text("服务器地址无效，需要形如 http://192.168.1.10:3080")
                        .font(.footnote)
                        .foregroundStyle(POSTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ActionButton(
                    title: model.phase.isPairing ? "正在配对…" : "开始配对",
                    systemImage: "link",
                    variant: .primary,
                    isBusy: model.phase.isPairing,
                    accessibility: "开始配对",
                    action: submit
                )
                .disabled(!canSubmit || model.phase.isPairing)

                hint
            }
            .padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("配对设备")
        .task {
            prepareFields()
        }
        .onChange(of: model.phase) { _, newValue in
            if newValue.isReady && didSubmit {
                dismiss()
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.xs) {
            Text(model.session == nil ? "连接你的 Personal OS" : "重新配对这台设备")
                .font(.title2.weight(.bold))
                .foregroundStyle(POSTheme.primaryText)
            Text("手机作为 client 设备接入 v2 云端；配对成功后可创建会话并同步消息。")
                .font(.subheadline)
                .foregroundStyle(POSTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
            labeledField(title: "服务器地址") {
                TextField("http://192.168.1.10:3080", text: $serverText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("服务器地址"))
            }

            labeledField(title: "配对密钥") {
                SecureField("配对密钥", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("配对密钥"))
            }

            labeledField(title: "设备名") {
                TextField("我的 iPhone", text: $deviceText)
                    .accessibilityLabel(Text("设备名"))
            }
        }
        .posCard()
    }

    private func labeledField<Content: View>(title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(POSTheme.secondaryText)

            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, POSTheme.Spacing.m)
                .padding(.vertical, POSTheme.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                        .fill(POSTheme.cardAlt)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                        .strokeBorder(POSTheme.stroke, lineWidth: 1)
                )
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.xs) {
            Text("配对密钥由云端管理员提供，只用于本次配对；设备令牌保存到本机 Keychain。")
            Text("请填写手机可以访问的 v2 云端地址。")
        }
        .font(.footnote)
        .foregroundStyle(POSTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 状态

    private var parsedURL: URL? {
        URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var serverTextIsInvalid: Bool {
        !serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !urlIsValid
    }

    private var urlIsValid: Bool {
        guard let url = parsedURL, let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private var canSubmit: Bool {
        urlIsValid && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 动作

    private func prepareFields() {
        guard !didPrepare else { return }
        didPrepare = true
        serverText = model.serverURL.absoluteString
        let existing = model.deviceName
        deviceText = existing.isEmpty ? "我的 iPhone" : existing
    }

    private func submit() {
        guard let url = parsedURL, urlIsValid else { return }
        didSubmit = true
        let name = deviceText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await model.pair(serverURL: url, secret: secret, deviceName: name)
        }
    }
}
