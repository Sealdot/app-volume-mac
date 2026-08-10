import Foundation

public struct AppVolumeRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var bundleIdentifier: String
    public var appName: String
    public var maximumVolume: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        maximumVolume: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.maximumVolume = Self.clamp(maximumVolume)
        self.isEnabled = isEnabled
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

public struct GuardSettings: Codable, Equatable {
    public var isProtectionEnabled: Bool
    public var defaultMaximumVolume: Double
    public var launchAtLogin: Bool
    public var notificationsEnabled: Bool
    public var appRules: [AppVolumeRule]

    public init(
        isProtectionEnabled: Bool = true,
        defaultMaximumVolume: Double = 0.70,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        appRules: [AppVolumeRule] = []
    ) {
        self.isProtectionEnabled = isProtectionEnabled
        self.defaultMaximumVolume = min(max(defaultMaximumVolume, 0), 1)
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.appRules = appRules
    }

    public func normalized() -> GuardSettings {
        var seen = Set<String>()
        var cleanRules: [AppVolumeRule] = []

        // Keep the last edited rule if a damaged or old settings payload has duplicates.
        for rule in appRules.reversed() {
            let bundleID = rule.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            cleanRules.append(
                AppVolumeRule(
                    id: rule.id,
                    bundleIdentifier: bundleID,
                    appName: rule.appName.isEmpty ? bundleID : rule.appName,
                    maximumVolume: rule.maximumVolume,
                    isEnabled: rule.isEnabled
                )
            )
        }

        return GuardSettings(
            isProtectionEnabled: isProtectionEnabled,
            defaultMaximumVolume: defaultMaximumVolume,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsEnabled,
            appRules: cleanRules.reversed()
        )
    }
}

public struct VolumeLimit: Equatable {
    public let value: Double
    public let sourceName: String
    public let isAppSpecific: Bool

    public init(value: Double, sourceName: String, isAppSpecific: Bool) {
        self.value = min(max(value, 0), 1)
        self.sourceName = sourceName
        self.isAppSpecific = isAppSpecific
    }
}

public struct ClampDecision: Equatable {
    public let previousVolume: Double
    public let targetVolume: Double
    public let limit: VolumeLimit

    public init(previousVolume: Double, targetVolume: Double, limit: VolumeLimit) {
        self.previousVolume = previousVolume
        self.targetVolume = targetVolume
        self.limit = limit
    }
}

public struct ProtectionEvent: Codable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let appName: String
    public let deviceName: String
    public let previousVolume: Double
    public let adjustedVolume: Double
    public let ruleName: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appName: String,
        deviceName: String,
        previousVolume: Double,
        adjustedVolume: Double,
        ruleName: String
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.deviceName = deviceName
        self.previousVolume = previousVolume
        self.adjustedVolume = adjustedVolume
        self.ruleName = ruleName
    }
}
