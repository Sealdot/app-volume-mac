import AppKit
import VolumeGuardCore

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let launchAtLoginManager: LaunchAtLoginManager

    // AppKit controls and the window are intentionally created only when the
    // user opens Settings. The menu-bar process stays small while idle.
    private var protectionCheckbox: NSButton!
    private var globalSlider: NSSlider!
    private var globalValueLabel: NSTextField!
    private var loginCheckbox: NSButton!
    private var notificationCheckbox: NSButton!
    private var runningAppsPopup: NSPopUpButton!
    private var rulesStack: NSStackView!
    private var runningApplications: [NSRunningApplication] = []
    private var settingsObserver: NSObjectProtocol?
    private var isPerformingUpdate = false

    init(settingsStore: SettingsStore, launchAtLoginManager: LaunchAtLoginManager) {
        self.settingsStore = settingsStore
        self.launchAtLoginManager = launchAtLoginManager

        super.init(window: nil)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.isWindowLoaded,
                  !self.isPerformingUpdate else { return }
            self.refreshAll()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func loadWindow() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 610),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "音量卫士设置"
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        window = settingsWindow

        createControls()
        buildInterface()
        refreshAll()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the complete control tree after closing so opening Settings
        // once does not permanently increase the menu-bar process footprint.
        DispatchQueue.main.async { [weak self] in
            self?.releaseWindowResources()
        }
    }

    private func releaseWindowResources() {
        window = nil
        protectionCheckbox = nil
        globalSlider = nil
        globalValueLabel = nil
        loginCheckbox = nil
        notificationCheckbox = nil
        runningAppsPopup = nil
        rulesStack = nil
        runningApplications.removeAll(keepingCapacity: false)
    }

    private func createControls() {
        protectionCheckbox = NSButton(checkboxWithTitle: "启用音量保护", target: nil, action: nil)
        globalSlider = NSSlider(value: 0.20, minValue: 0.20, maxValue: 1.00, target: nil, action: nil)
        globalValueLabel = NSTextField(labelWithString: "20%")
        loginCheckbox = NSButton(checkboxWithTitle: "登录 Mac 时自动启动", target: nil, action: nil)
        notificationCheckbox = NSButton(checkboxWithTitle: "自动调低时显示通知", target: nil, action: nil)
        runningAppsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        rulesStack = NSStackView()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18)
        ])

        let title = NSTextField(labelWithString: "避免意外高音量")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let summary = wrappingLabel(
            "只调节默认输出设备的系统音量，不录音、不上传数据，也不需要麦克风或辅助功能权限。"
        )
        root.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        protectionCheckbox.target = self
        protectionCheckbox.action = #selector(protectionChanged)
        root.addArrangedSubview(protectionCheckbox)

        let limitTitle = NSTextField(labelWithString: "默认音量上限")
        limitTitle.font = .systemFont(ofSize: 13, weight: .medium)
        root.addArrangedSubview(limitTitle)

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 10
        globalSlider.isContinuous = true
        globalSlider.target = self
        globalSlider.action = #selector(globalLimitChanged)
        globalValueLabel.alignment = .right
        globalValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sliderRow.addArrangedSubview(globalSlider)
        sliderRow.addArrangedSubview(globalValueLabel)
        root.addArrangedSubview(sliderRow)
        sliderRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        root.addArrangedSubview(loginCheckbox)

        notificationCheckbox.target = self
        notificationCheckbox.action = #selector(notificationChanged)
        root.addArrangedSubview(notificationCheckbox)

        root.addArrangedSubview(separator())

        let rulesTitle = NSTextField(labelWithString: "前台 App 上限（可选）")
        rulesTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(rulesTitle)

        let rulesHelp = wrappingLabel(
            "App 规则会覆盖默认上限。例如会议 App 设为 100%，音乐 App 设为 55%。规则按前台 App 判断，后台播放仍受默认上限保护。"
        )
        rulesHelp.textColor = .secondaryLabelColor
        root.addArrangedSubview(rulesHelp)
        rulesHelp.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8
        runningAppsPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let addButton = NSButton(title: "添加运行中的 App", target: self, action: #selector(addRule))
        addButton.bezelStyle = .rounded
        addRow.addArrangedSubview(runningAppsPopup)
        addRow.addArrangedSubview(addButton)
        root.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let rulesDocument = NSView()
        rulesDocument.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rulesDocument

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 0
        rulesStack.translatesAutoresizingMaskIntoConstraints = false
        rulesDocument.addSubview(rulesStack)

        NSLayoutConstraint.activate([
            rulesDocument.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rulesDocument.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rulesDocument.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rulesDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rulesStack.leadingAnchor.constraint(equalTo: rulesDocument.leadingAnchor),
            rulesStack.trailingAnchor.constraint(equalTo: rulesDocument.trailingAnchor),
            rulesStack.topAnchor.constraint(equalTo: rulesDocument.topAnchor),
            rulesStack.bottomAnchor.constraint(equalTo: rulesDocument.bottomAnchor)
        ])
        root.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 155).isActive = true

        let footer = wrappingLabel(
            "提示：HDMI、AirPlay 和部分外置 DAC 可能不提供可写的系统音量；状态栏会明确显示当前设备是否受保护。"
        )
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func refreshAll() {
        let settings = settingsStore.settings
        protectionCheckbox.state = settings.isProtectionEnabled ? .on : .off
        globalSlider.doubleValue = settings.defaultMaximumVolume
        globalValueLabel.stringValue = percent(settings.defaultMaximumVolume)
        loginCheckbox.state = launchAtLoginManager.isEnabled ? .on : .off
        notificationCheckbox.state = settings.notificationsEnabled ? .on : .off
        refreshRunningApplications()
        rebuildRuleRows(settings.appRules)
    }

    private func refreshRunningApplications() {
        let existingBundleIDs = Set(settingsStore.settings.appRules.map { $0.bundleIdentifier })
        runningApplications = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != Bundle.main.bundleIdentifier &&
                $0.bundleIdentifier != nil &&
                !existingBundleIDs.contains($0.bundleIdentifier ?? "")
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        runningAppsPopup.removeAllItems()
        if runningApplications.isEmpty {
            runningAppsPopup.addItem(withTitle: "没有可添加的 App")
            runningAppsPopup.isEnabled = false
        } else {
            runningAppsPopup.addItems(withTitles: runningApplications.map { $0.localizedName ?? "未知 App" })
            runningAppsPopup.isEnabled = true
        }
    }

    private func rebuildRuleRows(_ rules: [AppVolumeRule]) {
        for view in rulesStack.arrangedSubviews {
            rulesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if rules.isEmpty {
            let empty = NSTextField(labelWithString: "尚未添加 App 规则")
            empty.textColor = .secondaryLabelColor
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(empty)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 42),
                empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            rulesStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
            return
        }

        for rule in rules {
            let row = RuleRowView(rule: rule)
            row.onVolumeChanged = { [weak self] id, value in
                self?.updateRule(id: id, maximumVolume: value)
            }
            row.onRemove = { [weak self] id in
                self?.removeRule(id: id)
            }
            rulesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
    }

    @objc private func protectionChanged() {
        performSettingsUpdate {
            $0.isProtectionEnabled = protectionCheckbox.state == .on
        }
    }

    @objc private func globalLimitChanged() {
        let value = globalSlider.doubleValue
        globalValueLabel.stringValue = percent(value)
        performSettingsUpdate { $0.defaultMaximumVolume = value }
    }

    @objc private func loginChanged() {
        let shouldEnable = loginCheckbox.state == .on
        do {
            try launchAtLoginManager.setEnabled(shouldEnable)
            performSettingsUpdate { $0.launchAtLogin = shouldEnable }
        } catch {
            loginCheckbox.state = launchAtLoginManager.isEnabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func notificationChanged() {
        performSettingsUpdate {
            $0.notificationsEnabled = notificationCheckbox.state == .on
        }
    }

    @objc private func addRule() {
        let index = runningAppsPopup.indexOfSelectedItem
        guard runningApplications.indices.contains(index),
              let bundleID = runningApplications[index].bundleIdentifier else { return }
        let app = runningApplications[index]
        performSettingsUpdate {
            $0.appRules.append(AppVolumeRule(
                bundleIdentifier: bundleID,
                appName: app.localizedName ?? bundleID,
                maximumVolume: min($0.defaultMaximumVolume, 0.60)
            ))
        }
        refreshAll()
    }

    private func updateRule(id: UUID, maximumVolume: Double) {
        performSettingsUpdate { settings in
            guard let index = settings.appRules.firstIndex(where: { $0.id == id }) else { return }
            settings.appRules[index].maximumVolume = maximumVolume
        }
    }

    private func removeRule(id: UUID) {
        performSettingsUpdate {
            $0.appRules.removeAll { $0.id == id }
        }
        refreshAll()
    }

    private func performSettingsUpdate(_ mutation: (inout GuardSettings) -> Void) {
        isPerformingUpdate = true
        settingsStore.update(mutation)
        isPerformingUpdate = false
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return box
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private final class RuleRowView: NSView {
    var onVolumeChanged: ((UUID, Double) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private let ruleID: UUID
    private let slider: NSSlider
    private let valueLabel: NSTextField

    init(rule: AppVolumeRule) {
        ruleID = rule.id
        slider = NSSlider(value: rule.maximumVolume, minValue: 0.20, maxValue: 1.00, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "\(Int((rule.maximumVolume * 100).rounded()))%")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let appName = NSTextField(labelWithString: rule.appName)
        appName.font = .systemFont(ofSize: 12, weight: .medium)
        appName.lineBreakMode = .byTruncatingTail
        let bundleID = NSTextField(labelWithString: rule.bundleIdentifier)
        bundleID.font = .systemFont(ofSize: 9)
        bundleID.textColor = .secondaryLabelColor
        bundleID.lineBreakMode = .byTruncatingMiddle

        let appStack = NSStackView(views: [appName, bundleID])
        appStack.orientation = .vertical
        appStack.alignment = .leading
        appStack.spacing = 1
        appStack.translatesAutoresizingMaskIntoConstraints = false

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeTapped))
        removeButton.bezelStyle = .inline
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(appStack)
        addSubview(slider)
        addSubview(valueLabel)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            appStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            appStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            appStack.widthAnchor.constraint(equalToConstant: 145),
            slider.leadingAnchor.constraint(equalTo: appStack.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueLabel.widthAnchor.constraint(equalToConstant: 38),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 6),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sliderChanged() {
        valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        onVolumeChanged?(ruleID, slider.doubleValue)
    }

    @objc private func removeTapped() {
        onRemove?(ruleID)
    }
}
