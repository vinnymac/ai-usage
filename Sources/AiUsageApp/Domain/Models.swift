import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case copilot
    case claudeCode

    var id: String { rawValue }

    var usageSettingsURL: URL {
        switch self {
        case .codex:
            URL(string: "https://chatgpt.com/codex/cloud/settings/usage")!
        case .copilot:
            URL(string: "https://github.com/settings/copilot/features")!
        case .claudeCode:
            URL(string: "https://claude.ai/settings/usage")!
        }
    }

    var iconResourceName: String {
        switch self {
        case .codex:
            return "openai-icon"
        case .copilot:
            return "copilot-icon"
        case .claudeCode:
            return "claude-icon"
        }
    }

    func displayName(localizer: Localizer) -> String {
        switch self {
        case .codex:
            return localizer.text(.providerCodex)
        case .copilot:
            return localizer.text(.providerCopilot)
        case .claudeCode:
            return localizer.text(.providerClaudeCode)
        }
    }
}

enum UsageMetricKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case codexFiveHour
    case codexWeekly
    case codexCredits
    case copilotMonthly
    // Claude Code — web session path
    case claudeCodeFiveHour
    case claudeCodeWeeklyQuota
    // Claude Code — admin API path
    case claudeCodeDailyCost
    case claudeCodeWeeklyCost
    // Claude Code — both paths
    case claudeCodeSonnet

    var id: String { rawValue }

    var provider: ProviderID {
        switch self {
        case .codexFiveHour, .codexWeekly, .codexCredits:
            return .codex
        case .copilotMonthly:
            return .copilot
        case .claudeCodeFiveHour, .claudeCodeWeeklyQuota, .claudeCodeDailyCost, .claudeCodeWeeklyCost, .claudeCodeSonnet:
            return .claudeCode
        }
    }

    var participatesInMenuBarSummary: Bool {
        switch self {
        case .codexFiveHour, .codexWeekly, .copilotMonthly, .claudeCodeFiveHour, .claudeCodeWeeklyQuota, .claudeCodeDailyCost:
            return true
        case .codexCredits, .claudeCodeWeeklyCost, .claudeCodeSonnet:
            return false
        }
    }

    var supportsAheadNotifications: Bool {
        switch self {
        case .codexFiveHour, .codexWeekly, .copilotMonthly, .claudeCodeFiveHour, .claudeCodeWeeklyQuota:
            return true
        case .codexCredits, .claudeCodeDailyCost, .claudeCodeWeeklyCost, .claudeCodeSonnet:
            return false
        }
    }

    var supportsBehindNotifications: Bool {
        switch self {
        case .codexWeekly, .copilotMonthly, .claudeCodeWeeklyQuota:
            return true
        case .codexFiveHour, .codexCredits, .claudeCodeFiveHour, .claudeCodeDailyCost, .claudeCodeWeeklyCost, .claudeCodeSonnet:
            return false
        }
    }
}

enum MetricUnit: String, Codable, Hashable, Sendable {
    case percentage
    case requests
    case credits
    case cost
}

enum ProviderAuthState: String, Codable, Hashable, Sendable {
    case signedOut
    case configured
    case authenticated
}

enum ProviderFetchState: String, Codable, Hashable, Sendable {
    case ok
    case missingAuth
    case failed
}

enum UsageAlertDirection: String, Codable, Hashable, Sendable {
    case ahead
    case behind
}

struct UsageMetric: Codable, Identifiable, Hashable, Sendable {
    let kind: UsageMetricKind
    var remainingFraction: Double?
    var remainingValue: Double?
    var totalValue: Double?
    var unit: MetricUnit
    var resetAtUTC: Date?
    var lastUpdatedAtUTC: Date
    var detailText: String?

    var id: String { kind.rawValue }
}

struct ProviderSnapshot: Codable, Identifiable, Hashable, Sendable {
    let provider: ProviderID
    var authState: ProviderAuthState
    var fetchState: ProviderFetchState
    var fetchedAtUTC: Date?
    var metrics: [UsageMetric]
    var errorDescription: String?
    var sourceDescription: String?

    var id: String { provider.rawValue }

    func metric(_ kind: UsageMetricKind) -> UsageMetric? {
        metrics.first { $0.kind == kind }
    }
}

struct UsageAlertState: Codable, Hashable, Sendable {
    var direction: UsageAlertDirection
    var metricKind: UsageMetricKind
    var lastTriggeredAtUTC: Date
    var lastExtremeDelta: Double
    var lastResetAtUTC: Date?
    var isArmed: Bool
}

struct MenuBarSummaryItem: Identifiable, Hashable, Sendable {
    let provider: ProviderID
    let remainingFraction: Double?

    var id: String { provider.rawValue }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case englishUS
    case polish

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .englishUS:
            return Locale(identifier: "en_US")
        case .polish:
            return Locale(identifier: "pl_PL")
        }
    }
}

enum CodexMenuBarMetric: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case weekly
    case fiveHour

    var id: String { rawValue }

    var usageMetricKind: UsageMetricKind {
        switch self {
        case .weekly:
            return .codexWeekly
        case .fiveHour:
            return .codexFiveHour
        }
    }
}

enum ClaudeMenuBarMetric: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case fiveHour
    case weeklyQuota
    case dailyCost

    var id: String { rawValue }

    var usageMetricKind: UsageMetricKind {
        switch self {
        case .fiveHour:
            return .claudeCodeFiveHour
        case .weeklyQuota:
            return .claudeCodeWeeklyQuota
        case .dailyCost:
            return .claudeCodeDailyCost
        }
    }
}

struct DisplayPreferences: Codable, Hashable, Sendable {
    var visibleProviders: Set<ProviderID>
    var visiblePanelProviders: Set<ProviderID>
    var showAheadNotifications: Bool
    var showBehindNotifications: Bool
    var showCodexResetNotifications: Bool
    var showClaudeCodeResetNotifications: Bool
    var refreshIntervalMinutes: Int
    var language: AppLanguage
    var codexMenuBarMetric: CodexMenuBarMetric
    var claudeMenuBarMetric: ClaudeMenuBarMetric

    enum CodingKeys: String, CodingKey {
        case visibleProviders
        case visiblePanelProviders
        case showAheadNotifications
        case showBehindNotifications
        case showCodexResetNotifications
        case showClaudeCodeResetNotifications
        case refreshIntervalMinutes
        case language
        case codexMenuBarMetric
        case claudeMenuBarMetric
    }

    init(
        visibleProviders: Set<ProviderID>,
        visiblePanelProviders: Set<ProviderID>,
        showAheadNotifications: Bool,
        showBehindNotifications: Bool,
        showCodexResetNotifications: Bool,
        showClaudeCodeResetNotifications: Bool,
        refreshIntervalMinutes: Int,
        language: AppLanguage,
        codexMenuBarMetric: CodexMenuBarMetric,
        claudeMenuBarMetric: ClaudeMenuBarMetric
    ) {
        self.visibleProviders = visibleProviders
        self.visiblePanelProviders = visiblePanelProviders
        self.showAheadNotifications = showAheadNotifications
        self.showBehindNotifications = showBehindNotifications
        self.showCodexResetNotifications = showCodexResetNotifications
        self.showClaudeCodeResetNotifications = showClaudeCodeResetNotifications
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.language = language
        self.codexMenuBarMetric = codexMenuBarMetric
        self.claudeMenuBarMetric = claudeMenuBarMetric
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleProviders = try container.decode(Set<ProviderID>.self, forKey: .visibleProviders)
        visiblePanelProviders = try container.decodeIfPresent(Set<ProviderID>.self, forKey: .visiblePanelProviders) ?? Set(ProviderID.allCases)
        showAheadNotifications = try container.decode(Bool.self, forKey: .showAheadNotifications)
        showBehindNotifications = try container.decode(Bool.self, forKey: .showBehindNotifications)
        showCodexResetNotifications = try container.decode(Bool.self, forKey: .showCodexResetNotifications)
        showClaudeCodeResetNotifications = try container.decodeIfPresent(Bool.self, forKey: .showClaudeCodeResetNotifications) ?? true
        refreshIntervalMinutes = try container.decode(Int.self, forKey: .refreshIntervalMinutes)
        language = try container.decode(AppLanguage.self, forKey: .language)
        codexMenuBarMetric = try container.decodeIfPresent(CodexMenuBarMetric.self, forKey: .codexMenuBarMetric) ?? .weekly
        claudeMenuBarMetric = try container.decodeIfPresent(ClaudeMenuBarMetric.self, forKey: .claudeMenuBarMetric) ?? .fiveHour
    }

    func shouldRescheduleRefresh(comparedTo previous: Self) -> Bool {
        refreshIntervalMinutes != previous.refreshIntervalMinutes
    }

    static let `default` = DisplayPreferences(
        visibleProviders: Set(ProviderID.allCases),
        visiblePanelProviders: Set(ProviderID.allCases),
        showAheadNotifications: true,
        showBehindNotifications: true,
        showCodexResetNotifications: true,
        showClaudeCodeResetNotifications: true,
        refreshIntervalMinutes: 5,
        language: .englishUS,
        codexMenuBarMetric: .weekly,
        claudeMenuBarMetric: .fiveHour
    )
}
