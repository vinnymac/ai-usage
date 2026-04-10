import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var logStore: LogStore
    @State private var copilotTokenDraft = ""
    @State private var showCodexLoginSheet = false
    @State private var showCopilotLoginSheet = false
    @State private var showClaudeCodeLoginSheet = false
    @State private var statusMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self._logStore = ObservedObject(wrappedValue: environment.logStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                accountsTab
                    .tabItem {
                        Label(environment.localizer.text(.settingsTabAccounts), systemImage: "person.crop.circle")
                    }

                displayTab
                    .tabItem {
                        Label(environment.localizer.text(.settingsTabDisplay), systemImage: "rectangle.on.rectangle")
                    }

                notificationsTab
                    .tabItem {
                        Label(environment.localizer.text(.settingsTabNotifications), systemImage: "bell.badge")
                    }

                logsTab
                    .tabItem {
                        Label(environment.localizer.text(.settingsTabLogs), systemImage: "doc.text.magnifyingglass")
                    }

                aboutTab
                    .tabItem {
                        Label(environment.localizer.text(.settingsTabAbout), systemImage: "info.circle")
                    }
            }

            if let statusMessage, statusMessage.isEmpty == false {
                Divider()
                HStack {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 500)
        .sheet(isPresented: $showCodexLoginSheet) {
            CodexLoginSheet(localizer: environment.localizer) { session in
                try environment.saveCodexSession(session)
                await environment.refreshNow()
            }
        }
        .sheet(isPresented: $showCopilotLoginSheet) {
            CopilotLoginSheet(localizer: environment.localizer) { session in
                try environment.saveCopilotSession(session)
                await environment.refreshNow()
            }
        }
        .sheet(isPresented: $showClaudeCodeLoginSheet) {
            ClaudeCodeLoginSheet(
                localizer: environment.localizer,
                onSaveAdminKey: { key in
                    try environment.saveClaudeAdminKey(key)
                    await environment.refreshNow()
                }
            )
        }
    }

    private var accountsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                providerAccountGroup(provider: .codex) {
                    Text(environment.localizer.text(.codexSessionHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        if environment.currentAuthState(for: .codex) == .signedOut {
                            Button(environment.localizer.text(.signInToCodex)) {
                                showCodexLoginSheet = true
                            }
                        } else {
                            Button(environment.localizer.text(.signOut)) {
                                do {
                                    try environment.clearAuth(for: .codex)
                                    statusMessage = nil
                                } catch {
                                    statusMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                }

                providerAccountGroup(provider: .claudeCode) {
                    // Personal account (OAuth via Claude Code CLI)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(environment.localizer.text(.claudePersonalAccount))
                            .font(.subheadline.weight(.medium))

                        Text(environment.localizer.text(.claudePersonalAutoAuth))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            if environment.claudeOAuthEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(environment.localizer.text(.providerStatusOk))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button(environment.localizer.text(.signOut)) {
                                    environment.disconnectClaudeOAuth()
                                    statusMessage = nil
                                }
                            } else {
                                Button(environment.localizer.text(.claudeAllowAccess)) {
                                    if !environment.connectClaudeOAuth() {
                                        statusMessage = "No Claude Code credentials found. Run `claude` in Terminal to log in."
                                    } else {
                                        statusMessage = nil
                                        Task { await environment.refreshNow() }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Organization account (Admin API key)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(environment.localizer.text(.claudeOrganizationAccount))
                            .font(.subheadline.weight(.medium))

                        Text(environment.localizer.text(.claudeAdminApiKeyHelp))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            if environment.claudeAdminKeyConfigured {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(environment.localizer.text(.providerStatusOk))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button(environment.localizer.text(.claudeRemoveKey)) {
                                    do {
                                        try environment.removeClaudeAdminKey()
                                        statusMessage = nil
                                    } catch {
                                        statusMessage = error.localizedDescription
                                    }
                                }
                            } else {
                                Button(environment.localizer.text(.claudeAdminApiKey)) {
                                    showClaudeCodeLoginSheet = true
                                }
                            }
                        }
                    }
                }

                providerAccountGroup(provider: .copilot) {
                    Text(environment.localizer.text(.copilotPatHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(environment.localizer.text(.copilotPlanHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        if environment.currentAuthState(for: .copilot) == .signedOut {
                            SecureField(environment.localizer.text(.copilotToken), text: $copilotTokenDraft)
                                .textFieldStyle(.roundedBorder)

                            Button(environment.localizer.text(.saveAndRefresh)) {
                                Task {
                                    do {
                                        try environment.saveCopilotToken(copilotTokenDraft)
                                        copilotTokenDraft = ""
                                        statusMessage = environment.localizer.text(.tokenSaved)
                                        await environment.refreshNow()
                                    } catch {
                                        statusMessage = error.localizedDescription
                                    }
                                }
                            }

                            Button(environment.localizer.text(.signInToGitHubCopilot)) {
                                showCopilotLoginSheet = true
                            }
                        }

                        if environment.currentAuthState(for: .copilot) != .signedOut {
                            Button(environment.localizer.text(.signOut)) {
                                do {
                                    try environment.clearAuth(for: .copilot)
                                    statusMessage = nil
                                } catch {
                                    statusMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection(title: environment.localizer.text(.generalSection)) {
                    Picker(environment.localizer.text(.language), selection: $environment.settings.preferences.language) {
                        Text("English (US)").tag(AppLanguage.englishUS)
                        Text("Polski").tag(AppLanguage.polish)
                    }
                    .pickerStyle(.menu)

                    Picker(environment.localizer.text(.refreshInterval), selection: $environment.settings.preferences.refreshIntervalMinutes) {
                        Text("1 min").tag(1)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                    }
                    .pickerStyle(.menu)

                    Picker(environment.localizer.text(.codexMenuBarMetric), selection: $environment.settings.preferences.codexMenuBarMetric) {
                        Text(environment.localizer.text(.codexMenuBarMetricWeekly)).tag(CodexMenuBarMetric.weekly)
                        Text(environment.localizer.text(.codexMenuBarMetricFiveHour)).tag(CodexMenuBarMetric.fiveHour)
                    }
                    .pickerStyle(.menu)

                    Picker(environment.localizer.text(.claudeMenuBarMetric), selection: $environment.settings.preferences.claudeMenuBarMetric) {
                        Text(environment.localizer.text(.claudeMenuBarMetricFiveHour)).tag(ClaudeMenuBarMetric.fiveHour)
                        Text(environment.localizer.text(.claudeMenuBarMetricWeeklyQuota)).tag(ClaudeMenuBarMetric.weeklyQuota)
                        Text(environment.localizer.text(.claudeMenuBarMetricDailyCost)).tag(ClaudeMenuBarMetric.dailyCost)
                    }
                    .pickerStyle(.menu)
                }

                settingsSection(title: environment.localizer.text(.menuBarIcons)) {
                    ForEach(ProviderID.allCases) { provider in
                        Toggle(provider.displayName(localizer: environment.localizer), isOn: visibleProviderBinding(provider))
                    }
                }

                settingsSection(title: environment.localizer.text(.usagePanelSections)) {
                    ForEach(ProviderID.allCases) { provider in
                        Toggle(provider.displayName(localizer: environment.localizer), isOn: visiblePanelProviderBinding(provider))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notificationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection(title: environment.localizer.text(.notificationsSection)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(environment.localizer.text(.notificationsAhead), isOn: $environment.settings.preferences.showAheadNotifications)
                        Text(environment.localizer.text(.notificationsAheadDescription))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(environment.localizer.text(.notificationsBehind), isOn: $environment.settings.preferences.showBehindNotifications)
                        Text(environment.localizer.text(.notificationsBehindDescription))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(environment.localizer.text(.notificationsCodexReset), isOn: $environment.settings.preferences.showCodexResetNotifications)
                        Text(environment.localizer.text(.notificationsCodexResetDescription))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(environment.localizer.text(.notificationsClaudeCodeReset), isOn: $environment.settings.preferences.showClaudeCodeResetNotifications)
                        Text(environment.localizer.text(.notificationsClaudeCodeResetDescription))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(environment.localizer.text(.copyLogs)) {
                    let exportedLogs = logStore.exportText
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.declareTypes([.string], owner: nil)

                    if exportedLogs.isEmpty == false, pasteboard.setString(exportedLogs, forType: .string) {
                        statusMessage = environment.localizer.text(.logsCopied)
                    } else {
                        statusMessage = environment.localizer.text(.noLogs)
                    }
                }

                Button(environment.localizer.text(.clearLogs)) {
                    logStore.clear()
                    statusMessage = nil
                }

                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if logStore.entries.isEmpty {
                        Text(environment.localizer.text(.noLogs))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(logStore.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(logTimestamp(entry.timestampUTC)) • \(entry.level.rawValue.uppercased()) • \(entry.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(environment.localizer.text(.menuBarAppName))
                .font(.title2.weight(.semibold))

            Text("\(environment.localizer.text(.appVersion)) \(AppMetadata.version)")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Text(environment.localizer.text(.legalSection))
                .font(.headline)

            Text(environment.localizer.text(.logoDisclaimer))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func settingsSection(title: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title, title.isEmpty == false {
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerAccountGroup(provider: ProviderID, @ViewBuilder content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                accountHeader(provider: provider)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func visibleProviderBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: {
                environment.settings.preferences.visibleProviders.contains(provider)
            },
            set: { isVisible in
                var updated = environment.settings.preferences.visibleProviders
                if isVisible {
                    updated.insert(provider)
                } else if updated.count > 1 {
                    updated.remove(provider)
                }
                environment.settings.preferences.visibleProviders = updated
            }
        )
    }

    private func visiblePanelProviderBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: {
                environment.settings.preferences.visiblePanelProviders.contains(provider)
            },
            set: { isVisible in
                var updated = environment.settings.preferences.visiblePanelProviders
                if isVisible {
                    updated.insert(provider)
                } else {
                    updated.remove(provider)
                }
                environment.settings.preferences.visiblePanelProviders = updated
            }
        )
    }

    private func accountHeader(provider: ProviderID) -> some View {
        ProviderHeaderView(provider: provider, title: provider.displayName(localizer: environment.localizer), subtitle: authStatusText(provider))
    }

    private func authStatusText(_ provider: ProviderID) -> String {
        switch environment.currentAuthState(for: provider) {
        case .signedOut:
            return environment.localizer.text(.signedOut)
        case .configured, .authenticated:
            return environment.localizer.text(.providerStatusOk)
        }
    }

    private func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = environment.settings.preferences.language.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
}
