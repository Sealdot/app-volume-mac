import Foundation

public enum HeadphoneExitDecision: Equatable {
    case mute(adjustedVolume: Double)
    case reduce(targetVolume: Double)
    case unavailable
}

public enum ProtectionTrigger: Equatable {
    case startup
    case applicationChanged
    case outputDeviceChanged
    case systemWake
    case settingsChanged
    case resumed
    case manualCheck
    case volumeChanged

    /// Smart mode treats a volume-only change as an intentional adjustment.
    /// Strict mode enforces the ceiling after every volume change.
    public func shouldEnforceLimit(in mode: ProtectionMode) -> Bool {
        mode == .strict || self != .volumeChanged
    }

    /// Keeps a high-confidence check (for example, wake or settings changes)
    /// from being replaced by a lower-confidence duplicate device callback
    /// while evaluations are coalesced on the main queue.
    public var evaluationPriority: Int {
        switch self {
        case .volumeChanged:
            return 0
        case .applicationChanged, .outputDeviceChanged:
            return 1
        default:
            return 2
        }
    }

    /// Core Audio and NSWorkspace can emit duplicate context notifications for
    /// the app/device that is already active. Treating those duplicates as a
    /// fresh scene would repeatedly undo a user's manual volume adjustment.
    public func resolvingContextChange(_ contextDidChange: Bool) -> ProtectionTrigger {
        switch self {
        case .applicationChanged where !contextDidChange,
             .outputDeviceChanged where !contextDidChange:
            return .volumeChanged
        default:
            return self
        }
    }
}

public enum VolumePolicy {
    public static func headphoneExitDecision(
        settings: GuardSettings,
        previousCategory: AudioDeviceCategory?,
        currentCategory: AudioDeviceCategory,
        contextDidChange: Bool,
        isPaused: Bool,
        currentVolume: Double,
        effectiveLimit: Double,
        canSetVolume: Bool,
        canSetMute: Bool
    ) -> HeadphoneExitDecision? {
        guard settings.isProtectionEnabled,
              !isPaused,
              contextDidChange,
              previousCategory?.isHeadphone == true,
              !currentCategory.isHeadphone,
              settings.headphoneExitAction != .doNothing else { return nil }

        let current = min(max(currentVolume, 0), 1)
        let limit = min(max(effectiveLimit, 0), 1)
        switch settings.headphoneExitAction {
        case .doNothing:
            return nil
        case .mute where canSetMute:
            return .mute(adjustedVolume: canSetVolume ? min(current, limit) : current)
        case .mute, .reduceVolume:
            guard canSetVolume else { return .unavailable }
            let target = min(current, settings.headphoneExitVolume, limit)
            guard current > target + 0.005 else { return nil }
            return .reduce(targetVolume: target)
        }
    }

    /// An enabled foreground-app rule overrides the default limit. This lets a
    /// meeting app use a high limit while music apps stay conservative.
    public static func effectiveLimit(
        settings: GuardSettings,
        foregroundBundleIdentifier: String?,
        outputDeviceIdentifier: String? = nil,
        outputDeviceCategory: AudioDeviceCategory? = nil
    ) -> VolumeLimit {
        // An explicit foreground scene is the user's most specific choice.
        if let bundleID = foregroundBundleIdentifier,
           let rule = settings.appRules.last(where: {
               $0.isEnabled && $0.bundleIdentifier == bundleID
           }) {
            return VolumeLimit(
                value: rule.maximumVolume,
                sourceName: rule.appName,
                isAppSpecific: true
            )
        }

        if let deviceIdentifier = outputDeviceIdentifier,
           let rule = settings.deviceRules.last(where: {
               $0.isEnabled && $0.deviceIdentifier == deviceIdentifier
           }) {
            return VolumeLimit(
                value: rule.maximumVolume,
                sourceName: rule.deviceName,
                isAppSpecific: false
            )
        }

        if let category = outputDeviceCategory,
           let preset = settings.deviceTypePresets.last(where: {
               $0.isEnabled && $0.category == category
           }) {
            return VolumeLimit(
                value: preset.maximumVolume,
                sourceName: "\(category.displayName)预设",
                isAppSpecific: false
            )
        }

        return VolumeLimit(
            value: settings.defaultMaximumVolume,
            sourceName: "默认保护值",
            isAppSpecific: false
        )
    }

    public static func clampDecision(
        currentVolume: Double,
        settings: GuardSettings,
        foregroundBundleIdentifier: String?,
        outputDeviceIdentifier: String? = nil,
        outputDeviceCategory: AudioDeviceCategory? = nil,
        isPaused: Bool,
        trigger: ProtectionTrigger = .manualCheck,
        tolerance: Double = 0.005
    ) -> ClampDecision? {
        guard settings.isProtectionEnabled,
              !isPaused,
              trigger.shouldEnforceLimit(in: settings.protectionMode) else { return nil }
        let safeVolume = min(max(currentVolume, 0), 1)
        let limit = effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: foregroundBundleIdentifier,
            outputDeviceIdentifier: outputDeviceIdentifier,
            outputDeviceCategory: outputDeviceCategory
        )

        guard safeVolume > limit.value + max(0, tolerance) else { return nil }
        return ClampDecision(
            previousVolume: safeVolume,
            targetVolume: limit.value,
            limit: limit
        )
    }
}
