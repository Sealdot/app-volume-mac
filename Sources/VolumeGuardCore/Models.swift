import Foundation

public enum ProtectionMode: String, Codable, CaseIterable {
    case smart
    case strict

    public var displayName: String {
        switch self {
        case .smart: return "智能场景保护"
        case .strict: return "严格音量上限"
        }
    }
}

public enum HeadphoneExitAction: String, Codable, CaseIterable {
    case doNothing
    case mute
    case reduceVolume

    public var displayName: String {
        switch self {
        case .doNothing: return "不处理"
        case .mute: return "立即静音"
        case .reduceVolume: return "降至指定音量"
        }
    }
}

public enum AudioDeviceCategory: String, Codable, CaseIterable {
    case builtInSpeakers
    case wiredHeadphones
    case wirelessHeadphones
    case externalSpeakers
    case display
    case airPlay
    case usbAudio
    case other

    public var displayName: String {
        switch self {
        case .builtInSpeakers: return "内置扬声器"
        case .wiredHeadphones: return "有线耳机"
        case .wirelessHeadphones: return "无线耳机"
        case .externalSpeakers: return "外接扬声器"
        case .display: return "显示器音频"
        case .airPlay: return "AirPlay"
        case .usbAudio: return "USB 音频"
        case .other: return "其他设备"
        }
    }

    public var isHeadphone: Bool {
        self == .wiredHeadphones || self == .wirelessHeadphones
    }
}

public struct DeviceVolumeRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var deviceIdentifier: String
    public var deviceName: String
    public var maximumVolume: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        deviceIdentifier: String,
        deviceName: String,
        maximumVolume: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.maximumVolume = min(max(maximumVolume, 0), 1)
        self.isEnabled = isEnabled
    }
}

public struct DeviceTypePreset: Codable, Equatable, Identifiable {
    public var category: AudioDeviceCategory
    public var maximumVolume: Double
    public var isEnabled: Bool

    public var id: AudioDeviceCategory { category }

    public init(
        category: AudioDeviceCategory,
        maximumVolume: Double,
        isEnabled: Bool = true
    ) {
        self.category = category
        self.maximumVolume = min(max(maximumVolume, 0), 1)
        self.isEnabled = isEnabled
    }

    public static var recommendedDefaults: [DeviceTypePreset] {
        [
            DeviceTypePreset(category: .builtInSpeakers, maximumVolume: 0.40, isEnabled: false),
            DeviceTypePreset(category: .wiredHeadphones, maximumVolume: 0.25, isEnabled: false),
            DeviceTypePreset(category: .wirelessHeadphones, maximumVolume: 0.25, isEnabled: false),
            DeviceTypePreset(category: .externalSpeakers, maximumVolume: 0.35, isEnabled: false),
            DeviceTypePreset(category: .display, maximumVolume: 0.30, isEnabled: false),
            DeviceTypePreset(category: .airPlay, maximumVolume: 0.30, isEnabled: false),
            DeviceTypePreset(category: .usbAudio, maximumVolume: 0.30, isEnabled: false),
            DeviceTypePreset(category: .other, maximumVolume: 0.20, isEnabled: false)
        ]
    }
}

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
    public var protectionMode: ProtectionMode
    public var deviceRules: [DeviceVolumeRule]
    public var deviceTypePresets: [DeviceTypePreset]
    public var headphoneExitAction: HeadphoneExitAction
    public var headphoneExitVolume: Double
    public var hasCompletedOnboarding: Bool

    public init(
        isProtectionEnabled: Bool = true,
        defaultMaximumVolume: Double = 0.20,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        appRules: [AppVolumeRule] = [],
        protectionMode: ProtectionMode = .smart,
        deviceRules: [DeviceVolumeRule] = [],
        deviceTypePresets: [DeviceTypePreset] = DeviceTypePreset.recommendedDefaults,
        headphoneExitAction: HeadphoneExitAction = .mute,
        headphoneExitVolume: Double = 0.20,
        hasCompletedOnboarding: Bool = false
    ) {
        self.isProtectionEnabled = isProtectionEnabled
        self.defaultMaximumVolume = min(max(defaultMaximumVolume, 0), 1)
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.appRules = appRules
        self.protectionMode = protectionMode
        self.deviceRules = deviceRules
        self.deviceTypePresets = deviceTypePresets
        self.headphoneExitAction = headphoneExitAction
        self.headphoneExitVolume = min(max(headphoneExitVolume, 0), 1)
        self.hasCompletedOnboarding = hasCompletedOnboarding
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

        var seenDevices = Set<String>()
        var cleanDeviceRules: [DeviceVolumeRule] = []
        for rule in deviceRules.reversed() {
            let identifier = rule.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, !seenDevices.contains(identifier) else { continue }
            seenDevices.insert(identifier)
            cleanDeviceRules.append(DeviceVolumeRule(
                id: rule.id,
                deviceIdentifier: identifier,
                deviceName: rule.deviceName.isEmpty ? identifier : rule.deviceName,
                maximumVolume: rule.maximumVolume,
                isEnabled: rule.isEnabled
            ))
        }

        let presetsByCategory = Dictionary(
            deviceTypePresets.map { ($0.category, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let cleanPresets = AudioDeviceCategory.allCases.map { category in
            presetsByCategory[category]
                ?? DeviceTypePreset.recommendedDefaults.first(where: { $0.category == category })
                ?? DeviceTypePreset(category: category, maximumVolume: 0.20, isEnabled: false)
        }

        return GuardSettings(
            isProtectionEnabled: isProtectionEnabled,
            defaultMaximumVolume: defaultMaximumVolume,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsEnabled,
            appRules: cleanRules.reversed(),
            protectionMode: protectionMode,
            deviceRules: cleanDeviceRules.reversed(),
            deviceTypePresets: cleanPresets,
            headphoneExitAction: headphoneExitAction,
            headphoneExitVolume: headphoneExitVolume,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
    }


    private enum CodingKeys: String, CodingKey {
        case isProtectionEnabled
        case defaultMaximumVolume
        case launchAtLogin
        case notificationsEnabled
        case appRules
        case protectionMode
        case deviceRules
        case deviceTypePresets
        case headphoneExitAction
        case headphoneExitVolume
        case hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .isProtectionEnabled) ?? true
        defaultMaximumVolume = min(max(
            try container.decodeIfPresent(Double.self, forKey: .defaultMaximumVolume) ?? 0.20,
            0
        ), 1)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        appRules = try container.decodeIfPresent([AppVolumeRule].self, forKey: .appRules) ?? []
        protectionMode = try container.decodeIfPresent(ProtectionMode.self, forKey: .protectionMode) ?? .smart
        deviceRules = try container.decodeIfPresent([DeviceVolumeRule].self, forKey: .deviceRules) ?? []
        deviceTypePresets = try container.decodeIfPresent(
            [DeviceTypePreset].self,
            forKey: .deviceTypePresets
        ) ?? DeviceTypePreset.recommendedDefaults
        // Existing installations keep their old behavior until the user opts in.
        headphoneExitAction = try container.decodeIfPresent(
            HeadphoneExitAction.self,
            forKey: .headphoneExitAction
        ) ?? .doNothing
        headphoneExitVolume = min(max(
            try container.decodeIfPresent(Double.self, forKey: .headphoneExitVolume) ?? 0.20,
            0
        ), 1)
        // Do not interrupt an existing user with first-run UI after an upgrade.
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedOnboarding
        ) ?? true
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

public enum ProtectionEventKind: String, Codable {
    case volumeReduced
    case headphoneExitMuted
    case headphoneExitReduced
}

public struct ProtectionEvent: Codable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let appName: String
    public let deviceName: String
    public let previousVolume: Double
    public let adjustedVolume: Double
    public let ruleName: String
    public let kind: ProtectionEventKind

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appName: String,
        deviceName: String,
        previousVolume: Double,
        adjustedVolume: Double,
        ruleName: String,
        kind: ProtectionEventKind = .volumeReduced
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.deviceName = deviceName
        self.previousVolume = previousVolume
        self.adjustedVolume = adjustedVolume
        self.ruleName = ruleName
        self.kind = kind
    }


    private enum CodingKeys: String, CodingKey {
        case id, date, appName, deviceName, previousVolume, adjustedVolume, ruleName, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? "未知 App"
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "未知设备"
        previousVolume = try container.decodeIfPresent(Double.self, forKey: .previousVolume) ?? 0
        adjustedVolume = try container.decodeIfPresent(Double.self, forKey: .adjustedVolume) ?? 0
        ruleName = try container.decodeIfPresent(String.self, forKey: .ruleName) ?? "默认保护值"
        kind = try container.decodeIfPresent(ProtectionEventKind.self, forKey: .kind) ?? .volumeReduced
    }
}
