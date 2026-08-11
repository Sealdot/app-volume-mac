import Foundation

public enum ProtectionTrigger: Equatable {
    case startup
    case applicationChanged
    case outputDeviceChanged
    case settingsChanged
    case resumed
    case manualCheck
    case volumeChanged

    /// A volume-only change is treated as an intentional user adjustment.
    /// Risky context changes still enforce the configured protection value.
    public var shouldEnforceLimit: Bool {
        self != .volumeChanged
    }
}

public enum VolumePolicy {
    /// An enabled foreground-app rule overrides the default limit. This lets a
    /// meeting app use a high limit while music apps stay conservative.
    public static func effectiveLimit(
        settings: GuardSettings,
        foregroundBundleIdentifier: String?
    ) -> VolumeLimit {
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
        isPaused: Bool,
        trigger: ProtectionTrigger = .manualCheck,
        tolerance: Double = 0.005
    ) -> ClampDecision? {
        guard settings.isProtectionEnabled,
              !isPaused,
              trigger.shouldEnforceLimit else { return nil }
        let safeVolume = min(max(currentVolume, 0), 1)
        let limit = effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: foregroundBundleIdentifier
        )

        guard safeVolume > limit.value + max(0, tolerance) else { return nil }
        return ClampDecision(
            previousVolume: safeVolume,
            targetVolume: limit.value,
            limit: limit
        )
    }
}
