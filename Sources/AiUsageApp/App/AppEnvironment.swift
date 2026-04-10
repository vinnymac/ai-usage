import Combine
import Foundation
import AppKit
import SwiftUI

enum MenuBarSummaryEvaluator {
    static func remainingFraction(for provider: ProviderID, snapshot: ProviderSnapshot, preferences: DisplayPreferences) -> Double? {
        switch provider {
        case .codex:
            return snapshot.metric(preferences.codexMenuBarMetric.usageMetricKind)?.remainingFraction
        case .copilot:
            return snapshot.metric(.copilotMonthly)?.remainingFraction
        case .claudeCode:
            return snapshot.metric(preferences.claudeMenuBarMetric.usageMetricKind)?.remainingFraction
        }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var lastRefreshAtUTC: Date?
    @Published private(set) var isRefreshing = false
    @Published var lastRefreshError: String?
    @Published private(set) var claudeOAuthEnabled: Bool = false
    @Published private(set) var claudeAdminKeyConfigured: Bool = false

    var settings: SettingsStore
    let keychain: KeychainStore
    let usageStore: UsageStore
    let notificationService: NotificationService
    let logStore: LogStore

    private let codexProvider: CodexProvider
    private let copilotProvider: CopilotProvider
    private let claudeCodeProvider: ClaudeCodeProvider
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var refreshLoopTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore = SettingsStore(),
        keychain: KeychainStore = KeychainStore(),
        usageStore: UsageStore = UsageStore()
    ) {
        self.settings = settings
        self.keychain = keychain
        self.usageStore = usageStore
        self.logStore = LogStore()
        self.notificationService = NotificationService(usageStore: usageStore)
        self.codexProvider = CodexProvider(keychain: keychain, logStore: logStore)
        self.copilotProvider = CopilotProvider(keychain: keychain, logStore: logStore)
        self.claudeCodeProvider = ClaudeCodeProvider(keychain: keychain, logStore: logStore)
        self.claudeOAuthEnabled = self.claudeCodeProvider.oauthEnabled
        self.claudeAdminKeyConfigured = self.claudeCodeProvider.hasAdminKey
        let persistedSnapshots = usageStore.loadSnapshots()
        self.snapshots = persistedSnapshots.isEmpty ? [:] : persistedSnapshots
        self.lastRefreshAtUTC = persistedSnapshots.values.compactMap(\.fetchedAtUTC).max()

        if self.snapshots.isEmpty {
            bootstrapPlaceholderState()
        }

        observeSettings()
    }

    var localizer: Localizer {
        settings.localizer
    }

    var visibleMenuBarItems: [MenuBarSummaryItem] {
        settings.preferences.visibleProviders.compactMap { provider in
            let fraction = menuBarFraction(for: provider)
            return MenuBarSummaryItem(provider: provider, remainingFraction: fraction)
        }
        .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    func start() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(environment: self)
        }

        if statusItemController == nil {
            statusItemController = StatusItemController(environment: self)
        }

        logStore.append(category: "app", message: "Application started.")
        if notificationService.notificationsAreAvailable {
            notificationService.requestAuthorizationIfNeeded()
        } else {
            logStore.append(
                level: .warning,
                category: "app",
                message: "Skipping notification authorization because the process is not running from an .app bundle."
            )
        }
        scheduleRefreshLoop()
    }

    func showSettings() {
        closePanel()
        settingsWindowController?.show()
    }

    func closePanel() {
        statusItemController?.closePopover()
    }

    func quitApplication() {
        logStore.append(category: "app", message: "Application terminated by user.")
        NSApp.terminate(nil)
    }

    func refreshNow() async {
        guard isRefreshing == false else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        logStore.append(category: "refresh", message: "Refresh started for \(providers.count) providers.")
        let previousSnapshots = snapshots
        var updatedSnapshots: [ProviderID: ProviderSnapshot] = [:]
        var errors: [String] = []

        for provider in providers {
            let snapshot = await provider.refresh(now: now)
            updatedSnapshots[snapshot.provider] = snapshot
            logStore.append(
                level: snapshot.fetchState == .failed ? .error : .info,
                category: "refresh",
                message: "\(snapshot.provider.rawValue) -> \(snapshot.fetchState.rawValue), auth=\(snapshot.authState.rawValue), metrics=\(snapshot.metrics.count)"
            )

            if let errorDescription = snapshot.errorDescription, snapshot.fetchState == .failed {
                errors.append("\(snapshot.provider.rawValue.capitalized): \(errorDescription)")
            }
        }

        snapshots = updatedSnapshots
        lastRefreshAtUTC = now
        // Re-sync in case a provider auto-disabled credentials during refresh (e.g. expired token).
        claudeOAuthEnabled = claudeCodeProvider.oauthEnabled
        claudeAdminKeyConfigured = claudeCodeProvider.hasAdminKey
        lastRefreshError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if let lastRefreshError {
            logStore.append(level: .error, category: "refresh", message: "Refresh completed with errors: \(lastRefreshError)")
        } else {
            logStore.append(category: "refresh", message: "Refresh completed successfully.")
        }

        usageStore.saveSnapshots(updatedSnapshots)
        notificationService.processRefresh(previousSnapshots: previousSnapshots, newSnapshots: updatedSnapshots, preferences: settings.preferences, now: now)
    }

    func snapshot(for provider: ProviderID) -> ProviderSnapshot? {
        snapshots[provider]
    }

    func currentAuthState(for provider: ProviderID) -> ProviderAuthState {
        switch provider {
        case .codex:
            return codexProvider.currentAuthState()
        case .copilot:
            return copilotProvider.currentAuthState()
        case .claudeCode:
            return claudeCodeProvider.currentAuthState()
        }
    }

    func saveCopilotToken(_ token: String) throws {
        try copilotProvider.saveToken(token)
        logStore.append(category: "copilot", message: "Copilot token saved to Keychain.")
        bootstrapMissingSnapshot(for: .copilot)
    }

    func saveCopilotSession(_ session: CopilotSessionState) throws {
        try copilotProvider.saveSession(session)
        logStore.append(
            category: "copilot",
            message: "Saved GitHub Copilot session to Keychain with \(session.cookies.count) cookies."
        )
        bootstrapMissingSnapshot(for: .copilot)
    }

    func saveClaudeAdminKey(_ key: String) throws {
        try claudeCodeProvider.saveAdminKey(key)
        claudeAdminKeyConfigured = true
        logStore.append(category: "claude", message: "Claude Code Admin API key saved to Keychain.")
        bootstrapMissingSnapshot(for: .claudeCode)
    }

    func removeClaudeAdminKey() throws {
        try claudeCodeProvider.removeAdminKey()
        claudeAdminKeyConfigured = false
        logStore.append(category: "claude", message: "Claude Code Admin API key removed.")
        bootstrapMissingSnapshot(for: .claudeCode)
    }

    /// Attempts to read the Claude Code OAuth token from the Keychain.
    /// This may trigger a macOS Keychain permission dialog on first call.
    /// Returns `true` if a valid token was found.
    @discardableResult
    func connectClaudeOAuth() -> Bool {
        let success = claudeCodeProvider.enableOAuth()
        claudeOAuthEnabled = claudeCodeProvider.oauthEnabled
        if success {
            logStore.append(category: "claude", message: "Claude Code OAuth credentials found and enabled.")
            bootstrapMissingSnapshot(for: .claudeCode)
        } else {
            logStore.append(level: .warning, category: "claude", message: "Claude Code OAuth credentials not found. Is Claude Code installed and logged in?")
        }
        return success
    }

    func disconnectClaudeOAuth() {
        claudeCodeProvider.disableOAuth()
        claudeOAuthEnabled = false
        logStore.append(category: "claude", message: "Claude Code OAuth connection disabled.")
        bootstrapMissingSnapshot(for: .claudeCode)
    }

    func saveCodexSession(_ session: CodexSessionState) throws {
        try codexProvider.saveSession(session)
        logStore.append(
            category: "codex",
            message: "Saved Codex session to Keychain with \(session.cookies.count) cookies, \(session.localStorage.count) localStorage keys, and \(session.sessionStorage.count) sessionStorage keys."
        )
        bootstrapMissingSnapshot(for: .codex)
    }

    func clearAuth(for provider: ProviderID) throws {
        switch provider {
        case .codex:
            try codexProvider.clearAuth()
            logStore.append(category: "codex", message: "Codex session removed from Keychain.")
        case .copilot:
            try copilotProvider.clearAuth()
            logStore.append(category: "copilot", message: "Copilot credentials removed from Keychain.")
        case .claudeCode:
            try claudeCodeProvider.clearAuth()
            claudeOAuthEnabled = false
            claudeAdminKeyConfigured = false
            logStore.append(category: "claude", message: "Claude Code credentials removed from Keychain.")
        }

        bootstrapMissingSnapshot(for: provider)
        usageStore.saveSnapshots(snapshots)
    }

    func isStale(referenceDate: Date = Date()) -> Bool {
        guard let lastRefreshAtUTC else {
            return false
        }

        return referenceDate.timeIntervalSince(lastRefreshAtUTC) >= settings.stalenessThreshold
    }

    private func observeSettings() {
        settings.$preferences
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.$preferences
            .removeDuplicates(by: { previous, current in
                current.shouldRescheduleRefresh(comparedTo: previous) == false
            })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefreshLoop()
            }
            .store(in: &cancellables)
    }

    private func scheduleRefreshLoop() {
        refreshLoopTask?.cancel()

        let interval = settings.preferences.refreshIntervalMinutes

        refreshLoopTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.refreshNow()

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    return
                }

                await self.refreshNow()
            }
        }
    }

    private var providers: [UsageProvider] {
        [codexProvider, copilotProvider, claudeCodeProvider]
    }

    private func menuBarFraction(for provider: ProviderID) -> Double? {
        guard currentAuthState(for: provider) != .signedOut else { return nil }
        guard let snapshot = snapshots[provider] else { return nil }
        return MenuBarSummaryEvaluator.remainingFraction(for: provider, snapshot: snapshot, preferences: settings.preferences)
    }

    private func bootstrapPlaceholderState() {
        let now = Date()

        snapshots[.codex] = ProviderSnapshot(
            provider: .codex,
            authState: .signedOut,
            fetchState: .missingAuth,
            fetchedAtUTC: nil,
            metrics: [
                UsageMetric(kind: .codexFiveHour, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .codexWeekly, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .codexCredits, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .credits, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
            ],
            errorDescription: nil,
            sourceDescription: nil
        )

        snapshots[.copilot] = ProviderSnapshot(
            provider: .copilot,
            authState: .signedOut,
            fetchState: .missingAuth,
            fetchedAtUTC: nil,
            metrics: [
                UsageMetric(kind: .copilotMonthly, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
            ],
            errorDescription: nil,
            sourceDescription: nil
        )

        snapshots[.claudeCode] = ProviderSnapshot(
            provider: .claudeCode,
            authState: .signedOut,
            fetchState: .missingAuth,
            fetchedAtUTC: nil,
            metrics: [
                UsageMetric(kind: .claudeCodeFiveHour, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .claudeCodeWeeklyQuota, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .claudeCodeDailyCost, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .cost, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .claudeCodeWeeklyCost, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .cost, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
                UsageMetric(kind: .claudeCodeSonnet, remainingFraction: nil, remainingValue: nil, totalValue: nil, unit: .percentage, resetAtUTC: nil, lastUpdatedAtUTC: now, detailText: nil),
            ],
            errorDescription: nil,
            sourceDescription: nil
        )
    }

    private func bootstrapMissingSnapshot(for provider: ProviderID) {
        let now = Date()

        switch provider {
        case .codex:
            snapshots[.codex] = ProviderSnapshot(
                provider: .codex,
                authState: currentAuthState(for: .codex),
                fetchState: currentAuthState(for: .codex) == .signedOut ? .missingAuth : .failed,
                fetchedAtUTC: snapshots[.codex]?.fetchedAtUTC,
                metrics: [
                    UsageMetric(kind: .codexFiveHour, remainingFraction: snapshots[.codex]?.metric(.codexFiveHour)?.remainingFraction, remainingValue: snapshots[.codex]?.metric(.codexFiveHour)?.remainingValue, totalValue: snapshots[.codex]?.metric(.codexFiveHour)?.totalValue, unit: .percentage, resetAtUTC: snapshots[.codex]?.metric(.codexFiveHour)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: snapshots[.codex]?.metric(.codexFiveHour)?.detailText),
                    UsageMetric(kind: .codexWeekly, remainingFraction: snapshots[.codex]?.metric(.codexWeekly)?.remainingFraction, remainingValue: snapshots[.codex]?.metric(.codexWeekly)?.remainingValue, totalValue: snapshots[.codex]?.metric(.codexWeekly)?.totalValue, unit: .percentage, resetAtUTC: snapshots[.codex]?.metric(.codexWeekly)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: snapshots[.codex]?.metric(.codexWeekly)?.detailText),
                    UsageMetric(kind: .codexCredits, remainingFraction: nil, remainingValue: snapshots[.codex]?.metric(.codexCredits)?.remainingValue, totalValue: nil, unit: .credits, resetAtUTC: snapshots[.codex]?.metric(.codexCredits)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: snapshots[.codex]?.metric(.codexCredits)?.detailText),
                ],
                errorDescription: nil,
                sourceDescription: codexProvider.sourceDescription
            )
        case .copilot:
            snapshots[.copilot] = ProviderSnapshot(
                provider: .copilot,
                authState: currentAuthState(for: .copilot),
                fetchState: currentAuthState(for: .copilot) == .signedOut ? .missingAuth : .failed,
                fetchedAtUTC: snapshots[.copilot]?.fetchedAtUTC,
                metrics: [
                    UsageMetric(kind: .copilotMonthly, remainingFraction: snapshots[.copilot]?.metric(.copilotMonthly)?.remainingFraction, remainingValue: snapshots[.copilot]?.metric(.copilotMonthly)?.remainingValue, totalValue: snapshots[.copilot]?.metric(.copilotMonthly)?.totalValue, unit: .requests, resetAtUTC: snapshots[.copilot]?.metric(.copilotMonthly)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: snapshots[.copilot]?.metric(.copilotMonthly)?.detailText),
                ],
                errorDescription: nil,
                sourceDescription: copilotProvider.sourceDescription
            )
        case .claudeCode:
            let authState = currentAuthState(for: .claudeCode)
            snapshots[.claudeCode] = ProviderSnapshot(
                provider: .claudeCode,
                authState: authState,
                fetchState: authState == .signedOut ? .missingAuth : .failed,
                fetchedAtUTC: snapshots[.claudeCode]?.fetchedAtUTC,
                metrics: [
                    UsageMetric(kind: .claudeCodeFiveHour, remainingFraction: snapshots[.claudeCode]?.metric(.claudeCodeFiveHour)?.remainingFraction, remainingValue: snapshots[.claudeCode]?.metric(.claudeCodeFiveHour)?.remainingValue, totalValue: snapshots[.claudeCode]?.metric(.claudeCodeFiveHour)?.totalValue, unit: .percentage, resetAtUTC: snapshots[.claudeCode]?.metric(.claudeCodeFiveHour)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: nil),
                    UsageMetric(kind: .claudeCodeWeeklyQuota, remainingFraction: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyQuota)?.remainingFraction, remainingValue: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyQuota)?.remainingValue, totalValue: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyQuota)?.totalValue, unit: .percentage, resetAtUTC: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyQuota)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: nil),
                    UsageMetric(kind: .claudeCodeDailyCost, remainingFraction: nil, remainingValue: snapshots[.claudeCode]?.metric(.claudeCodeDailyCost)?.remainingValue, totalValue: nil, unit: .cost, resetAtUTC: snapshots[.claudeCode]?.metric(.claudeCodeDailyCost)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: nil),
                    UsageMetric(kind: .claudeCodeWeeklyCost, remainingFraction: nil, remainingValue: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyCost)?.remainingValue, totalValue: nil, unit: .cost, resetAtUTC: snapshots[.claudeCode]?.metric(.claudeCodeWeeklyCost)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: nil),
                    UsageMetric(kind: .claudeCodeSonnet, remainingFraction: snapshots[.claudeCode]?.metric(.claudeCodeSonnet)?.remainingFraction, remainingValue: snapshots[.claudeCode]?.metric(.claudeCodeSonnet)?.remainingValue, totalValue: snapshots[.claudeCode]?.metric(.claudeCodeSonnet)?.totalValue, unit: .percentage, resetAtUTC: snapshots[.claudeCode]?.metric(.claudeCodeSonnet)?.resetAtUTC, lastUpdatedAtUTC: now, detailText: nil),
                ],
                errorDescription: nil,
                sourceDescription: claudeCodeProvider.sourceDescription
            )
        }
    }
}
