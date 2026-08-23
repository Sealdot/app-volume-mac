import Foundation
import VolumeGuardCore

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

private func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private let checks: [(String, () throws -> Void)] = [
    ("首次安装默认上限为 20%", {
        let settings = GuardSettings()
        try expect(close(settings.defaultMaximumVolume, 0.20), "首次安装默认上限应为 20%")
    }),
    ("无匹配规则时使用默认上限", {
        let settings = GuardSettings(defaultMaximumVolume: 0.70)
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: "com.example.unknown"
        )
        try expect(close(limit.value, 0.70), "默认上限错误")
        try expect(!limit.isAppSpecific, "默认上限不应标记为 App 规则")
    }),
    ("前台 App 规则覆盖默认上限", {
        let rule = AppVolumeRule(
            bundleIdentifier: "com.apple.Music",
            appName: "音乐",
            maximumVolume: 0.55
        )
        let settings = GuardSettings(defaultMaximumVolume: 0.70, appRules: [rule])
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: "com.apple.Music"
        )
        try expect(close(limit.value, 0.55), "App 上限错误")
        try expect(limit.sourceName == "音乐", "规则名称错误")
        try expect(limit.isAppSpecific, "应标记为 App 规则")
    }),
    ("当前设备规则覆盖默认上限", {
        let deviceRule = DeviceVolumeRule(
            deviceIdentifier: "speaker-1",
            deviceName: "桌面扬声器",
            maximumVolume: 0.45
        )
        let settings = GuardSettings(defaultMaximumVolume: 0.20, deviceRules: [deviceRule])
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: nil,
            outputDeviceIdentifier: "speaker-1",
            outputDeviceCategory: .externalSpeakers
        )
        try expect(close(limit.value, 0.45), "设备规则未生效")
        try expect(limit.sourceName == "桌面扬声器", "设备规则来源错误")
    }),
    ("设备类型预设在无精确规则时生效", {
        let presets = [DeviceTypePreset(
            category: .wirelessHeadphones,
            maximumVolume: 0.25,
            isEnabled: true
        )]
        let settings = GuardSettings(defaultMaximumVolume: 0.60, deviceTypePresets: presets)
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: nil,
            outputDeviceIdentifier: "airpods",
            outputDeviceCategory: .wirelessHeadphones
        )
        try expect(close(limit.value, 0.25), "设备类型预设未生效")
        try expect(limit.sourceName == "无线耳机预设", "类型预设来源错误")
    }),
    ("规则优先级为场景、设备、类型、默认值", {
        let appRule = AppVolumeRule(
            bundleIdentifier: "com.apple.Music",
            appName: "音乐",
            maximumVolume: 0.55
        )
        let deviceRule = DeviceVolumeRule(
            deviceIdentifier: "airpods",
            deviceName: "AirPods",
            maximumVolume: 0.35
        )
        let preset = DeviceTypePreset(
            category: .wirelessHeadphones,
            maximumVolume: 0.25,
            isEnabled: true
        )
        let settings = GuardSettings(
            defaultMaximumVolume: 0.20,
            appRules: [appRule],
            deviceRules: [deviceRule],
            deviceTypePresets: [preset]
        )
        let appLimit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: "com.apple.Music",
            outputDeviceIdentifier: "airpods",
            outputDeviceCategory: .wirelessHeadphones
        )
        try expect(close(appLimit.value, 0.55), "场景规则应优先")
        let deviceLimit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: nil,
            outputDeviceIdentifier: "airpods",
            outputDeviceCategory: .wirelessHeadphones
        )
        try expect(close(deviceLimit.value, 0.35), "精确设备规则应优先于类型")
    }),
    ("禁用的 App 规则回退到默认上限", {
        let rule = AppVolumeRule(
            bundleIdentifier: "com.apple.Music",
            appName: "音乐",
            maximumVolume: 0.20,
            isEnabled: false
        )
        let settings = GuardSettings(defaultMaximumVolume: 0.70, appRules: [rule])
        let value = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: "com.apple.Music"
        ).value
        try expect(close(value, 0.70), "禁用规则不应生效")
    }),
    ("超过上限时生成降音量决策", {
        let decision = VolumePolicy.clampDecision(
            currentVolume: 1.0,
            settings: GuardSettings(defaultMaximumVolume: 0.65),
            foregroundBundleIdentifier: nil,
            isPaused: false
        )
        try expect(close(decision?.previousVolume ?? 0, 1.0), "原始音量错误")
        try expect(close(decision?.targetVolume ?? 0, 0.65), "目标音量错误")
    }),
    ("用户手动调高音量时不抢回控制权", {
        let decision = VolumePolicy.clampDecision(
            currentVolume: 1.0,
            settings: GuardSettings(defaultMaximumVolume: 0.20),
            foregroundBundleIdentifier: nil,
            isPaused: false,
            trigger: .volumeChanged
        )
        try expect(decision == nil, "手动音量变化不应被立即压回")
    }),
    ("严格模式会压回手动超限音量", {
        let decision = VolumePolicy.clampDecision(
            currentVolume: 0.80,
            settings: GuardSettings(
                defaultMaximumVolume: 0.30,
                protectionMode: .strict
            ),
            foregroundBundleIdentifier: nil,
            isPaused: false,
            trigger: .volumeChanged
        )
        try expect(close(decision?.targetVolume ?? 0, 0.30), "严格模式未持续执行上限")
    }),
    ("耳机离开时优先静音并同步降低标量", {
        let decision = VolumePolicy.headphoneExitDecision(
            settings: GuardSettings(headphoneExitAction: .mute),
            previousCategory: .wirelessHeadphones,
            currentCategory: .builtInSpeakers,
            contextDidChange: true,
            isPaused: false,
            currentVolume: 0.80,
            effectiveLimit: 0.30,
            canSetVolume: true,
            canSetMute: true
        )
        try expect(decision == .mute(adjustedVolume: 0.30), "耳机离开静音决策错误")
    }),
    ("静音不可用时耳机离开保护回退到指定音量", {
        let decision = VolumePolicy.headphoneExitDecision(
            settings: GuardSettings(
                headphoneExitAction: .mute,
                headphoneExitVolume: 0.18
            ),
            previousCategory: .wiredHeadphones,
            currentCategory: .externalSpeakers,
            contextDidChange: true,
            isPaused: false,
            currentVolume: 0.90,
            effectiveLimit: 0.40,
            canSetVolume: true,
            canSetMute: false
        )
        try expect(decision == .reduce(targetVolume: 0.18), "耳机离开回退音量错误")
    }),
    ("耳机之间切换、暂停或音量已安全时不触发离开保护", {
        let settings = GuardSettings(headphoneExitAction: .mute)
        let headphoneSwitch = VolumePolicy.headphoneExitDecision(
            settings: settings,
            previousCategory: .wiredHeadphones,
            currentCategory: .wirelessHeadphones,
            contextDidChange: true,
            isPaused: false,
            currentVolume: 0.80,
            effectiveLimit: 0.20,
            canSetVolume: true,
            canSetMute: true
        )
        try expect(headphoneSwitch == nil, "耳机之间切换不应静音")
        let paused = VolumePolicy.headphoneExitDecision(
            settings: settings,
            previousCategory: .wiredHeadphones,
            currentCategory: .builtInSpeakers,
            contextDidChange: true,
            isPaused: true,
            currentVolume: 0.80,
            effectiveLimit: 0.20,
            canSetVolume: true,
            canSetMute: true
        )
        try expect(paused == nil, "暂停期间不应执行耳机离开保护")
        let alreadySafe = VolumePolicy.headphoneExitDecision(
            settings: GuardSettings(
                headphoneExitAction: .reduceVolume,
                headphoneExitVolume: 0.20
            ),
            previousCategory: .wiredHeadphones,
            currentCategory: .builtInSpeakers,
            contextDidChange: true,
            isPaused: false,
            currentVolume: 0.18,
            effectiveLimit: 0.30,
            canSetVolume: true,
            canSetMute: false
        )
        try expect(alreadySafe == nil, "音量已经安全时不应记录空操作")
    }),
    ("重复 App 或设备通知不应抢回手动音量", {
        let settings = GuardSettings(defaultMaximumVolume: 0.20)
        for trigger in [ProtectionTrigger.applicationChanged, .outputDeviceChanged] {
            let resolved = trigger.resolvingContextChange(false)
            let decision = VolumePolicy.clampDecision(
                currentVolume: 1.0,
                settings: settings,
                foregroundBundleIdentifier: nil,
                isPaused: false,
                trigger: resolved
            )
            try expect(decision == nil, "重复场景通知应视为手动音量变化")
        }
    }),
    ("真实场景变化和唤醒仍执行保护", {
        let settings = GuardSettings(defaultMaximumVolume: 0.20)
        for trigger in [
            ProtectionTrigger.applicationChanged.resolvingContextChange(true),
            ProtectionTrigger.outputDeviceChanged.resolvingContextChange(true),
            ProtectionTrigger.systemWake
        ] {
            let decision = VolumePolicy.clampDecision(
                currentVolume: 1.0,
                settings: settings,
                foregroundBundleIdentifier: nil,
                isPaused: false,
                trigger: trigger
            )
            try expect(close(decision?.targetVolume ?? 0, 0.20), "真实场景变化应执行保护")
        }
        try expect(
            ProtectionTrigger.systemWake.evaluationPriority
                > ProtectionTrigger.outputDeviceChanged.evaluationPriority,
            "唤醒检查不应被重复设备通知覆盖"
        )
    }),
    ("切换 App 时仍执行保护", {
        let decision = VolumePolicy.clampDecision(
            currentVolume: 1.0,
            settings: GuardSettings(defaultMaximumVolume: 0.20),
            foregroundBundleIdentifier: "com.apple.Music",
            isPaused: false,
            trigger: .applicationChanged
        )
        try expect(close(decision?.targetVolume ?? 0, 0.20), "场景切换应执行保护")
    }),
    ("等于或低于上限时不写音量", {
        let settings = GuardSettings(defaultMaximumVolume: 0.65)
        try expect(VolumePolicy.clampDecision(
            currentVolume: 0.65,
            settings: settings,
            foregroundBundleIdentifier: nil,
            isPaused: false
        ) == nil, "等于上限不应触发")
        try expect(VolumePolicy.clampDecision(
            currentVolume: 0.30,
            settings: settings,
            foregroundBundleIdentifier: nil,
            isPaused: false
        ) == nil, "低于上限不应触发")
    }),
    ("暂停或关闭时不干预", {
        try expect(VolumePolicy.clampDecision(
            currentVolume: 1.0,
            settings: GuardSettings(isProtectionEnabled: true, defaultMaximumVolume: 0.50),
            foregroundBundleIdentifier: nil,
            isPaused: true
        ) == nil, "暂停时不应触发")
        try expect(VolumePolicy.clampDecision(
            currentVolume: 1.0,
            settings: GuardSettings(isProtectionEnabled: false, defaultMaximumVolume: 0.50),
            foregroundBundleIdentifier: nil,
            isPaused: false
        ) == nil, "关闭时不应触发")
    }),
    ("边界值被标准化到 0...1", {
        try expect(close(GuardSettings(defaultMaximumVolume: 2).defaultMaximumVolume, 1), "全局上限未限制")
        try expect(close(AppVolumeRule(
            bundleIdentifier: "com.example.app",
            appName: "Example",
            maximumVolume: -1
        ).maximumVolume, 0), "App 上限未限制")
    }),
    ("重复 Bundle ID 保留最新规则", {
        let old = AppVolumeRule(bundleIdentifier: "com.apple.Music", appName: "Old", maximumVolume: 0.8)
        let latest = AppVolumeRule(bundleIdentifier: "com.apple.Music", appName: "Latest", maximumVolume: 0.5)
        let settings = GuardSettings(appRules: [old, latest]).normalized()
        try expect(settings.appRules.count == 1, "重复规则未清理")
        try expect(settings.appRules.first?.appName == "Latest", "未保留最新规则")
    }),
    ("设备规则去重且设备类型预设补全", {
        let old = DeviceVolumeRule(
            deviceIdentifier: "speaker",
            deviceName: "Old",
            maximumVolume: 0.80
        )
        let latest = DeviceVolumeRule(
            deviceIdentifier: "speaker",
            deviceName: "Latest",
            maximumVolume: 0.40
        )
        let settings = GuardSettings(
            deviceRules: [old, latest],
            deviceTypePresets: [DeviceTypePreset(
                category: .wiredHeadphones,
                maximumVolume: 0.25,
                isEnabled: true
            )]
        ).normalized()
        try expect(settings.deviceRules.count == 1, "重复设备规则未清理")
        try expect(settings.deviceRules.first?.deviceName == "Latest", "未保留最新设备规则")
        try expect(
            settings.deviceTypePresets.count == AudioDeviceCategory.allCases.count,
            "设备类型预设未补全"
        )
    }),
    ("新安装默认开启耳机离开静音和首次引导", {
        let settings = GuardSettings()
        try expect(settings.headphoneExitAction == .mute, "新安装应默认开启耳机离开静音")
        try expect(!settings.hasCompletedOnboarding, "新安装应显示首次引导")
        try expect(settings.protectionMode == .smart, "默认应使用智能模式")
    }),
    ("旧设置迁移时保持原行为且不重复引导", {
        let payload = Data("""
        {"isProtectionEnabled":true,"defaultMaximumVolume":0.42,"launchAtLogin":false,"notificationsEnabled":true,"appRules":[]}
        """.utf8)
        let settings = try JSONDecoder().decode(GuardSettings.self, from: payload).normalized()
        try expect(settings.headphoneExitAction == .doNothing, "旧设置不应自动开启断开动作")
        try expect(settings.hasCompletedOnboarding, "旧用户不应被重复引导")
        try expect(settings.protectionMode == .smart, "旧设置应迁移为智能模式")
        try expect(
            settings.deviceTypePresets.count == AudioDeviceCategory.allCases.count,
            "迁移后应补全设备类型预设"
        )
    }),
    ("设置可以持久化", {
        let suite = "VolumeGuardChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure.failed("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsStore(defaults: defaults, storageKey: "settings")
        first.update {
            $0.defaultMaximumVolume = 0.42
            $0.launchAtLogin = true
            $0.protectionMode = .strict
            $0.headphoneExitAction = .reduceVolume
            $0.headphoneExitVolume = 0.16
            $0.hasCompletedOnboarding = true
            $0.deviceRules = [DeviceVolumeRule(
                deviceIdentifier: "persistent-device",
                deviceName: "Persistent Device",
                maximumVolume: 0.31
            )]
        }
        let second = SettingsStore(defaults: defaults, storageKey: "settings")
        try expect(close(second.settings.defaultMaximumVolume, 0.42), "上限未持久化")
        try expect(second.settings.launchAtLogin, "登录启动设置未持久化")
        try expect(second.settings.protectionMode == .strict, "保护模式未持久化")
        try expect(second.settings.headphoneExitAction == .reduceVolume, "耳机动作未持久化")
        try expect(close(second.settings.headphoneExitVolume, 0.16), "耳机回退值未持久化")
        try expect(second.settings.hasCompletedOnboarding, "引导状态未持久化")
        try expect(
            second.settings.deviceRules.first?.deviceIdentifier == "persistent-device",
            "设备规则未持久化"
        )
    }),
    ("移除 App 规则后重启不会恢复", {
        let suite = "VolumeGuardChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure.failed("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = AppVolumeRule(
            bundleIdentifier: "com.example.removed",
            appName: "Removed",
            maximumVolume: 0.20
        )
        let first = SettingsStore(defaults: defaults, storageKey: "settings")
        first.update { $0.appRules = [rule] }
        first.update { $0.appRules.removeAll { $0.id == rule.id } }
        let reopened = SettingsStore(defaults: defaults, storageKey: "settings")
        try expect(reopened.settings.appRules.isEmpty, "已移除规则不应在重启后恢复")
    }),
    ("损坏的配置回退到安全默认值", {
        let suite = "VolumeGuardChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure.failed("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "settings")
        let store = SettingsStore(defaults: defaults, storageKey: "settings")
        try expect(store.settings.isProtectionEnabled, "默认应开启保护")
        try expect(close(store.settings.defaultMaximumVolume, 0.20), "默认上限应为 20%")
    }),
    ("事件历史有数量上限", {
        let suite = "VolumeGuardChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure.failed("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProtectionEventStore(defaults: defaults, storageKey: "events", maximumCount: 2)
        for index in 1...3 {
            store.append(ProtectionEvent(
                appName: "App \(index)",
                deviceName: "Speaker",
                previousVolume: 1,
                adjustedVolume: 0.5,
                ruleName: "Default"
            ))
        }
        try expect(store.events.count == 2, "历史数量未限制")
        try expect(store.events.first?.appName == "App 3", "未保留最新事件")
    }),
    ("旧保护事件迁移为音量降低类型", {
        struct LegacyEvent: Codable {
            let id: UUID
            let date: Date
            let appName: String
            let deviceName: String
            let previousVolume: Double
            let adjustedVolume: Double
            let ruleName: String
        }
        let payload = try JSONEncoder().encode(LegacyEvent(
            id: UUID(),
            date: Date(),
            appName: "Music",
            deviceName: "Speaker",
            previousVolume: 0.8,
            adjustedVolume: 0.2,
            ruleName: "Default"
        ))
        let event = try JSONDecoder().decode(ProtectionEvent.self, from: payload)
        try expect(event.kind == .volumeReduced, "旧事件类型迁移错误")
    })
]

var failed = 0
for (name, check) in checks {
    do {
        try check()
        print("✓ \(name)")
    } catch {
        failed += 1
        print("✗ \(name)：\(error)")
    }
}

if failed > 0 {
    print("\n\(failed) / \(checks.count) 项检查失败")
    exit(1)
}

print("\n全部 \(checks.count) 项核心检查通过")
