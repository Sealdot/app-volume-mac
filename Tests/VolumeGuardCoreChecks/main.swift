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
        }
        let second = SettingsStore(defaults: defaults, storageKey: "settings")
        try expect(close(second.settings.defaultMaximumVolume, 0.42), "上限未持久化")
        try expect(second.settings.launchAtLogin, "登录启动设置未持久化")
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
