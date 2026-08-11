import AppKit
import VolumeGuardCore

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let settingsStore: SettingsStore
    private let eventStore: ProtectionEventStore
    private let protectionController: ProtectionController
    private let settingsWindowController: SettingsWindowController
    private var status: GuardRuntimeStatus

    init(
        settingsStore: SettingsStore,
        eventStore: ProtectionEventStore,
        protectionController: ProtectionController,
        settingsWindowController: SettingsWindowController
    ) {
        self.settingsStore = settingsStore
        self.eventStore = eventStore
        self.protectionController = protectionController
        self.settingsWindowController = settingsWindowController
        self.status = protectionController.status
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        updateStatus(status)
    }

    func updateStatus(_ status: GuardRuntimeStatus) {
        self.status = status
        guard let button = statusItem.button else { return }

        let symbolName: String
        let accessibilityDescription: String
        switch status.state {
        case .protecting:
            if status.isManualOverrideActive {
                symbolName = "speaker.wave.3.circle.fill"
                accessibilityDescription = "音量卫士：已保留手动音量"
            } else {
                symbolName = "speaker.wave.2.circle.fill"
                accessibilityDescription = "音量卫士：场景保护中"
            }
        case .paused:
            symbolName = "pause.circle.fill"
            accessibilityDescription = "音量卫士：已暂停"
        case .disabled:
            symbolName = "speaker.slash.circle"
            accessibilityDescription = "音量卫士：已关闭"
        case .unsupported:
            symbolName = "exclamationmark.triangle.fill"
            accessibilityDescription = "音量卫士：当前设备不支持"
        }

        if #available(macOS 11.0, *) {
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: accessibilityDescription
            )
            button.image = image
            button.title = image == nil ? "VG" : ""
        } else {
            button.image = nil
            button.title = "VG"
        }
        button.toolTip = accessibilityDescription
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let headline = NSMenuItem(title: headlineText(), action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)

        let context = NSMenuItem(
            title: "\(status.foregroundAppName) · \(status.deviceName)",
            action: nil,
            keyEquivalent: ""
        )
        context.isEnabled = false
        menu.addItem(context)
        menu.addItem(.separator())

        let protectionItem = NSMenuItem(
            title: "启用音量保护",
            action: #selector(toggleProtection),
            keyEquivalent: ""
        )
        protectionItem.target = self
        protectionItem.state = settingsStore.settings.isProtectionEnabled ? .on : .off
        menu.addItem(protectionItem)

        if case .paused = status.state {
            let resumeItem = NSMenuItem(title: "立即恢复保护", action: #selector(resumeProtection), keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else if settingsStore.settings.isProtectionEnabled {
            let pauseItem = NSMenuItem(title: "暂停保护", action: nil, keyEquivalent: "")
            let pauseMenu = NSMenu()
            pauseMenu.addItem(actionItem("15 分钟", action: #selector(pause15Minutes)))
            pauseMenu.addItem(actionItem("1 小时", action: #selector(pauseOneHour)))
            pauseMenu.addItem(actionItem("直到手动恢复", action: #selector(pauseIndefinitely)))
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        if let lastEvent = eventStore.events.first {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: String(
                    format: "最近保护：%@ %d%% → %d%%",
                    lastEvent.appName,
                    Int((lastEvent.previousVolume * 100).rounded()),
                    Int((lastEvent.adjustedVolume * 100).rounded())
                ),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        if let error = status.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if status.foregroundBundleIdentifier != nil {
            let hasRule = settingsStore.settings.appRules.contains {
                $0.bundleIdentifier == status.foregroundBundleIdentifier
            }
            let title = hasRule
                ? "编辑 \(status.foregroundAppName) 规则…"
                : "为 \(status.foregroundAppName) 添加规则…"
            menu.addItem(actionItem(title, action: #selector(openCurrentAppRule)))
        }
        let source = NSMenuItem(
            title: "生效规则：\(status.effectiveLimit.sourceName)",
            action: nil,
            keyEquivalent: ""
        )
        source.isEnabled = false
        menu.addItem(source)
        menu.addItem(.separator())
        menu.addItem(actionItem("设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(actionItem("立即执行保护", action: #selector(checkNow)))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出音量卫士", action: #selector(quit), keyEquivalent: "q"))
    }

    private func headlineText() -> String {
        let current = status.currentVolume.map(percent) ?? "--"
        let limit = percent(status.effectiveLimit.value)

        switch status.state {
        case .protecting:
            if status.isManualOverrideActive {
                return "手动音量 \(current) · 场景切换时保护到 \(limit)"
            }
            return "保护中 · 当前 \(current) · 保护值 \(limit)"
        case let .paused(until):
            if let until = until {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return "已暂停 · \(formatter.string(from: until)) 自动恢复"
            }
            return "已暂停 · 等待手动恢复"
        case .disabled:
            return "保护已关闭 · 当前 \(current)"
        case .unsupported:
            return "当前设备不支持系统音量保护"
        }
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    @objc private func toggleProtection() {
        settingsStore.update { $0.isProtectionEnabled.toggle() }
    }

    @objc private func pause15Minutes() {
        protectionController.pause(for: 15 * 60)
    }

    @objc private func pauseOneHour() {
        protectionController.pause(for: 60 * 60)
    }

    @objc private func pauseIndefinitely() {
        protectionController.pause(for: nil)
    }

    @objc private func resumeProtection() {
        protectionController.resume()
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow(self)
    }

    @objc private func openCurrentAppRule() {
        settingsWindowController.showRules(
            addingBundleIdentifier: status.foregroundBundleIdentifier,
            appName: status.foregroundAppName
        )
    }

    @objc private func checkNow() {
        protectionController.evaluateNow()
    }

    @objc private func quit() {
        NSApp.terminate(self)
    }
}
