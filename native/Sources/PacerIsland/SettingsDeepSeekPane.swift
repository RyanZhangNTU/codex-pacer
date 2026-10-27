import AppKit
import PacerCore
import SwiftUI

/// DeepSeek's module page below the shared header: sessions found on this
/// Mac, where the balance comes from, and how spending is shown. A connected
/// wallet shows only its state and time, never the account.
struct SettingsDeepSeekSections: View {
    @ObservedObject var model: IslandModel
    @Binding var balanceSource: DeepSeekBalanceSource
    @Binding var lowBalance: Double
    @Binding var showsTurnCost: Bool
    @Binding var home: String
    let homeIssue: String?
    let commitHome: () -> Void
    let chooseHome: () -> Void
    @State private var key = ""
    @State private var keyIssue: String?
    @State private var showsLocation = !(UserDefaults.standard.string(forKey: "deepseekHome") ?? "").isEmpty

    var body: some View {
        Section(L10n.text("provider.section.local")) {
            let status = model.providerStreamStatuses(.deepseek)["local"]
            row(L10n.text("deepseek.sessions"), state: L10n.text(status?.connected == true ? "provider.state.found" : "provider.state.no_home"),
                tint: status?.connected == true ? .green : .secondary)
            DisclosureGroup(L10n.text("provider.custom_locations"), isExpanded: $showsLocation) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(L10n.text("deepseek.home"), text: $home, prompt: Text("~/.dsh")).onSubmit(commitHome)
                        Button(L10n.text("common.choose"), action: chooseHome)
                    }
                    if let homeIssue { caption(homeIssue).foregroundStyle(.orange) }
                }.padding(.top, 6)
            }
        }
        Section {
            Picker(L10n.text("deepseek.balance_source"), selection: $balanceSource) {
                Text(L10n.text("deepseek.source.automatic")).tag(DeepSeekBalanceSource.automatic)
                Text(L10n.text("deepseek.source.web_short")).tag(DeepSeekBalanceSource.web)
                Text(L10n.text("deepseek.source.api_short")).tag(DeepSeekBalanceSource.apiKey)
            }
            .pickerStyle(.segmented)
            caption(detectionText)
            connectionRow
            if model.deepseekBalanceMode == .apiKey { keyEditor }
            LabeledContent(L10n.text("deepseek.low_balance")) {
                HStack(spacing: 4) {
                    Text("¥").foregroundStyle(.secondary)
                    TextField("", value: $lowBalance, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(width: 64).labelsHidden()
                }
            }
            if let alert = model.deepseekBalance?.alertBound {
                caption(L10n.text("deepseek.low_balance_platform", DeepSeekWallet.compactAmount(alert)))
            }
        } header: {
            Text(L10n.text("deepseek.section.balance"))
        }
        Section {
            Toggle(isOn: $showsTurnCost) {
                Text(L10n.text("deepseek.turn_cost"))
                Text(L10n.text("deepseek.turn_cost_help"))
            }
            caption(L10n.text("deepseek.pricing_note"))
        } header: {
            Text(L10n.text("deepseek.section.spending"))
        }
    }

    private var detectionText: String {
        let detected = model.deepseekDetectedMode
        let found = detected.map { L10n.text($0 == .account ? "deepseek.detected.account" : "deepseek.detected.api") } ?? L10n.text("deepseek.detected.unknown")
        return balanceSource == .automatic ? found : L10n.text("deepseek.detected.overridden", found)
    }

    @ViewBuilder private var connectionRow: some View {
        let web = model.deepseekBalanceMode != .apiKey
        let connected = model.deepseekBalance != nil && !model.deepseekConnectionNeeded
        let (tint, state): (Color, String) =
            connected ? (.green, L10n.text("deepseek.connected", model.deepseekBalanceFreshness)) :
            model.deepseekRefreshing ? (.secondary, L10n.text("claude.account.checking")) :
            model.deepseekConnectionNeeded || model.deepseekBalanceError == nil ? (.orange, L10n.text(web ? "deepseek.signed_out" : "deepseek.no_key")) :
            (.orange, model.deepseekBalanceError?.errorDescription ?? L10n.text("deepseek.balance.unavailable"))
        row(L10n.text(web ? "deepseek.platform_account" : "deepseek.api_key"), state: state, tint: tint) {
            if web {
                if connected {
                    Menu {
                        Button(L10n.text("claude.account.switch")) { model.connectDeepSeek() }
                        Button(L10n.text("deepseek.sign_out")) { model.removeDeepSeekConnection() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L10n.text("claude.account.options"))
                } else {
                    Button(L10n.text("deepseek.sign_in")) { model.connectDeepSeek() }
                }
            } else if model.deepseekBalanceError != nil || connected {
                Button(L10n.text("common.refresh")) { model.refreshDeepSeekBalance(force: true) }.disabled(model.deepseekRefreshing)
            }
        }
    }

    @ViewBuilder private var keyEditor: some View {
        HStack {
            SecureField(L10n.text("deepseek.paste_key"), text: $key, prompt: Text("sk-…")).onSubmit(saveKey)
            Button(L10n.text("common.save"), action: saveKey).disabled(key.isEmpty)
            if DeepSeekAPIKeyStore.exists { Button(L10n.text("deepseek.remove_key")) { model.removeDeepSeekConnection() } }
        }
        caption(keyIssue ?? L10n.text("deepseek.key_help")).foregroundStyle(keyIssue == nil ? Color.secondary : Color.orange)
    }
    private func saveKey() {
        // The field clears either way; a key never stays in view state.
        defer { key = "" }
        keyIssue = model.saveDeepSeekAPIKey(key) ? nil : L10n.text("deepseek.key_invalid")
    }

    private func row<Action: View>(_ title: String, state: String, tint: Color, @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(state).foregroundStyle(tint == .orange ? Color.orange : Color.secondary)
            action()
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
