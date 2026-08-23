import AppKit
import VolumeGuardCore

private enum SettingsPane {
    case general
    case rules
    case devices
    case history
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let generalToolbarIdentifier = NSToolbarItem.Identifier("VolumeGuard.General")
    private static let rulesToolbarIdentifier = NSToolbarItem.Identifier("VolumeGuard.Rules")
    private static let devicesToolbarIdentifier = NSToolbarItem.Identifier("VolumeGuard.Devices")
    private static let historyToolbarIdentifier = NSToolbarItem.Identifier("VolumeGuard.History")
    private static let settingsContentSize = NSSize(width: 700, height: 520)

    private let settingsStore: SettingsStore
    private let eventStore: ProtectionEventStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let protectionController: ProtectionController

    private var selectedPane: SettingsPane = .general
    private var hasBuiltWindow = false
    private var settingsObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?
    private var eventsObserver: NSObjectProtocol?
    private var isPerformingUpdate = false

    private var generalView: NSView!
    private var rulesView: NSView!
    private var devicesView: DevicesSettingsView!
    private var historyView: HistorySettingsView!
    private var protectionSwitch: NSSwitch!
    private var protectionModePopup: NSPopUpButton!
    private var globalSlider: NSSlider!
    private var globalValueLabel: NSTextField!
    private var loginSwitch: NSSwitch!
    private var notificationSwitch: NSSwitch!
    private var statusIconView: NSImageView!
    private var statusTitleLabel: NSTextField!
    private var statusDetailLabel: NSTextField!
    private var statusRuleLabel: NSTextField!
    private var runningAppsPopup: NSPopUpButton!
    private var addRunningAppButton: NSButton!
    private var rulesStack: NSStackView!
    private var runningApplications: [NSRunningApplication] = []

    init(
        settingsStore: SettingsStore,
        eventStore: ProtectionEventStore,
        launchAtLoginManager: LaunchAtLoginManager,
        protectionController: ProtectionController
    ) {
        self.settingsStore = settingsStore
        self.eventStore = eventStore
        self.launchAtLoginManager = launchAtLoginManager
        self.protectionController = protectionController
        super.init(window: nil)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.hasBuiltWindow,
                  !self.isPerformingUpdate else { return }
            self.refreshAll()
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: ProtectionController.didChangeNotification,
            object: protectionController,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.hasBuiltWindow else { return }
            self.refreshStatus()
        }
        eventsObserver = NotificationCenter.default.addObserver(
            forName: ProtectionEventStore.didChangeNotification,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.hasBuiltWindow else { return }
            self.historyView?.apply(events: self.eventStore.events)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = settingsObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = eventsObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadWindow() {
        guard !hasBuiltWindow else { return }
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.settingsContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.title = title(for: selectedPane)
        settingsWindow.center()

        let toolbar = NSToolbar(identifier: "VolumeGuard.SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = toolbarIdentifier(for: selectedPane)
        settingsWindow.toolbar = toolbar
        if #available(macOS 11.0, *) {
            settingsWindow.toolbarStyle = .preference
        }

        window = settingsWindow
        hasBuiltWindow = true
        createControls()
        generalView = buildGeneralView()
        rulesView = buildRulesView()
        devicesView = DevicesSettingsView(
            onDeviceRuleChanged: { [weak self] snapshot, enabled, value in
                self?.updateDeviceRule(snapshot: snapshot, enabled: enabled, maximumVolume: value)
            },
            onHeadphoneActionChanged: { [weak self] action in
                self?.performSettingsUpdate { $0.headphoneExitAction = action }
            },
            onHeadphoneVolumeChanged: { [weak self] value in
                self?.performSettingsUpdate { $0.headphoneExitVolume = value }
            },
            onTypePresetChanged: { [weak self] category, enabled, value in
                self?.updateTypePreset(category: category, enabled: enabled, maximumVolume: value)
            }
        )
        historyView = HistorySettingsView(onClear: { [weak self] in
            self?.eventStore.removeAll()
        })
        showSelectedPane()
        refreshAll()
    }

    override func showWindow(_ sender: Any?) {
        if !hasBuiltWindow { loadWindow() }
        refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func showRules() {
        selectedPane = .rules
        showWindow(nil)
        showSelectedPane()
    }

    func showDevices() {
        selectedPane = .devices
        showWindow(nil)
        showSelectedPane()
    }

    func showHistory() {
        selectedPane = .history
        showWindow(nil)
        showSelectedPane()
    }

    @discardableResult
    func writeSnapshot(to url: URL) -> Bool {
        guard let window = window, let view = window.contentView else { return false }
        window.displayIfNeeded()
        if url.pathExtension.lowercased() == "pdf" {
            do {
                try view.dataWithPDF(inside: view.bounds).write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Exercises the same target/action path as a real click for UI smoke tests.
    @discardableResult
    func removeFirstRuleForTesting() -> Bool {
        selectedPane = .rules
        showWindow(nil)
        showSelectedPane()
        window?.displayIfNeeded()
        let before = settingsStore.settings.appRules.count
        guard before > 0,
              let removedRule = settingsStore.settings.appRules.first,
              let row = rulesStack.arrangedSubviews.compactMap({ $0 as? RuleRowView }).first else {
            return false
        }
        row.performRemoveForTesting()
        showRules()
        let expectedCount = before - 1
        let displayedCount = rulesStack.arrangedSubviews.compactMap { $0 as? RuleRowView }.count
        return settingsStore.settings.appRules.count == expectedCount
            && displayedCount == expectedCount
            && !settingsStore.settings.appRules.contains { $0.bundleIdentifier == removedRule.bundleIdentifier }
    }

    func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.window === closingWindow,
                  closingWindow?.isVisible == false else { return }
            self.releaseWindowResources()
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.generalToolbarIdentifier,
            Self.rulesToolbarIdentifier,
            Self.devicesToolbarIdentifier,
            Self.historyToolbarIdentifier
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        switch itemIdentifier {
        case Self.generalToolbarIdentifier:
            item.label = "通用"
            item.paletteLabel = "通用"
            item.toolTip = "通用设置"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "通用")
            } else {
                item.image = NSImage(named: NSImage.preferencesGeneralName)
            }
        case Self.rulesToolbarIdentifier:
            item.label = "场景规则"
            item.paletteLabel = "场景规则"
            item.toolTip = "前台 App 场景规则"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "app.badge.checkmark", accessibilityDescription: "场景规则")
            } else {
                item.image = NSImage(named: NSImage.applicationIconName)
            }
        case Self.devicesToolbarIdentifier:
            item.label = "设备"
            item.paletteLabel = "设备"
            item.toolTip = "输出设备保护"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "设备")
            } else {
                item.image = NSImage(named: NSImage.advancedName)
            }
        case Self.historyToolbarIdentifier:
            item.label = "历史"
            item.paletteLabel = "历史"
            item.toolTip = "最近保护历史"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "历史")
            } else {
                item.image = NSImage(named: NSImage.infoName)
            }
        default:
            return nil
        }
        return item
    }

    private func createControls() {
        protectionSwitch = makeSwitch(action: #selector(protectionChanged))
        protectionModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        protectionModePopup.addItems(withTitles: ProtectionMode.allCases.map { $0.displayName })
        protectionModePopup.target = self
        protectionModePopup.action = #selector(protectionModeChanged)
        protectionModePopup.setAccessibilityLabel("保护模式")
        globalSlider = NSSlider(
            value: settingsStore.settings.defaultMaximumVolume,
            minValue: 0.05,
            maxValue: 1.00,
            target: self,
            action: #selector(globalLimitChanged)
        )
        globalSlider.isContinuous = true
        globalSlider.setAccessibilityLabel("默认场景保护值")
        globalValueLabel = NSTextField(labelWithString: "20%")
        globalValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        globalValueLabel.alignment = .right
        loginSwitch = makeSwitch(action: #selector(loginChanged))
        notificationSwitch = makeSwitch(action: #selector(notificationChanged))

        statusIconView = NSImageView()
        statusIconView.imageScaling = .scaleProportionallyUpOrDown
        statusTitleLabel = NSTextField(labelWithString: "正在检测…")
        statusTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusDetailLabel = NSTextField(labelWithString: "")
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.font = .systemFont(ofSize: 12)
        statusRuleLabel = NSTextField(labelWithString: "")
        statusRuleLabel.textColor = .secondaryLabelColor
        statusRuleLabel.font = .systemFont(ofSize: 12)

        runningAppsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        runningAppsPopup.setAccessibilityLabel("正在运行的 App")
        addRunningAppButton = NSButton(title: "添加", target: self, action: #selector(addRunningAppRule))
        addRunningAppButton.bezelStyle = .rounded
        rulesStack = NSStackView()
    }

    private func buildGeneralView() -> NSView {
        let view = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14)
        ])

        root.addArrangedSubview(sectionTitle("当前状态"))
        let statusBox = makeGroupBox()
        statusBox.translatesAutoresizingMaskIntoConstraints = false
        let statusContent = NSStackView()
        statusContent.orientation = .horizontal
        statusContent.alignment = .centerY
        statusContent.spacing = 12
        statusContent.translatesAutoresizingMaskIntoConstraints = false
        statusBox.contentView?.addSubview(statusContent)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        statusIconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let statusText = NSStackView(views: [statusTitleLabel, statusDetailLabel, statusRuleLabel])
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 2
        statusContent.addArrangedSubview(statusIconView)
        statusContent.addArrangedSubview(statusText)
        if let content = statusBox.contentView {
            NSLayoutConstraint.activate([
                statusContent.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                statusContent.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                statusContent.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                statusContent.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
            ])
        }
        root.addArrangedSubview(statusBox)
        statusBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        statusBox.heightAnchor.constraint(equalToConstant: 86).isActive = true

        root.addArrangedSubview(sectionTitle("保护设置"))
        let settingsBox = makeGroupBox()
        let settingsStack = NSStackView()
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 0
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsBox.contentView?.addSubview(settingsStack)
        if let content = settingsBox.contentView {
            NSLayoutConstraint.activate([
                settingsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                settingsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                settingsStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
                settingsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
            ])
        }

        settingsStack.addArrangedSubview(makeSwitchRow(
            title: "音量保护",
            detail: "按生效规则降低系统音量，绝不自动调高",
            control: protectionSwitch
        ))
        settingsStack.addArrangedSubview(separator())
        settingsStack.addArrangedSubview(makeChoiceRow(
            title: "保护模式",
            detail: "智能模式尊重手调；严格模式持续执行上限",
            control: protectionModePopup
        ))
        settingsStack.addArrangedSubview(separator())
        settingsStack.addArrangedSubview(makeLimitRow())
        settingsStack.addArrangedSubview(separator())
        settingsStack.addArrangedSubview(makeSwitchRow(
            title: "登录时启动",
            detail: "登录 Mac 后静默驻留菜单栏",
            control: loginSwitch
        ))
        settingsStack.addArrangedSubview(separator())
        settingsStack.addArrangedSubview(makeSwitchRow(
            title: "保护通知",
            detail: "实际调低音量时显示系统通知",
            control: notificationSwitch
        ))
        root.addArrangedSubview(settingsBox)
        settingsBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        settingsBox.heightAnchor.constraint(equalToConstant: 294).isActive = true

        let privacy = wrappingLabel("只读取和调节系统音量，不录音、不联网。20% 是防止意外高音量的默认值，不代表安全分贝。")
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        return view
    }

    private func buildRulesView() -> NSView {
        let view = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14)
        ])

        root.addArrangedSubview(sectionTitle("规则说明"))
        let infoBox = makeGroupBox()
        infoBox.translatesAutoresizingMaskIntoConstraints = false
        let infoContent = NSStackView()
        infoContent.orientation = .horizontal
        infoContent.alignment = .centerY
        infoContent.spacing = 12
        infoContent.translatesAutoresizingMaskIntoConstraints = false
        infoBox.contentView?.addSubview(infoContent)

        let infoIcon = NSImageView()
        if #available(macOS 11.0, *) {
            infoIcon.image = NSImage(
                systemSymbolName: "app.badge.checkmark",
                accessibilityDescription: "场景规则"
            )
        }
        infoIcon.contentTintColor = .systemBlue
        infoIcon.translatesAutoresizingMaskIntoConstraints = false
        infoIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        infoIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let infoTitle = NSTextField(labelWithString: "按前台 App 切换场景保护值")
        infoTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let infoDetail = NSTextField(labelWithString: "这是场景规则，不是后台发声 App 的独立混音器")
        infoDetail.textColor = .secondaryLabelColor
        infoDetail.font = .systemFont(ofSize: 12)
        let scopeNote = NSTextField(labelWithString: "优先级：前台场景 → 当前设备 → 设备类型预设 → 默认值")
        scopeNote.textColor = .secondaryLabelColor
        scopeNote.font = .systemFont(ofSize: 11)
        let infoText = NSStackView(views: [infoTitle, infoDetail, scopeNote])
        infoText.orientation = .vertical
        infoText.alignment = .leading
        infoText.spacing = 2
        infoContent.addArrangedSubview(infoIcon)
        infoContent.addArrangedSubview(infoText)
        if let content = infoBox.contentView {
            NSLayoutConstraint.activate([
                infoContent.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                infoContent.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                infoContent.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                infoContent.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
            ])
        }
        root.addArrangedSubview(infoBox)
        infoBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        infoBox.heightAnchor.constraint(equalToConstant: 86).isActive = true

        root.addArrangedSubview(sectionTitle("规则管理"))
        let rulesBox = makeGroupBox()
        rulesBox.translatesAutoresizingMaskIntoConstraints = false
        let managementStack = NSStackView()
        managementStack.orientation = .vertical
        managementStack.alignment = .leading
        managementStack.spacing = 0
        managementStack.translatesAutoresizingMaskIntoConstraints = false
        rulesBox.contentView?.addSubview(managementStack)
        if let content = rulesBox.contentView {
            NSLayoutConstraint.activate([
                managementStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                managementStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                managementStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
                managementStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
            ])
        }
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8
        runningAppsPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "选择 App…", target: self, action: #selector(chooseInstalledApp))
        chooseButton.bezelStyle = .rounded
        addRow.addArrangedSubview(runningAppsPopup)
        addRow.addArrangedSubview(addRunningAppButton)
        addRow.addArrangedSubview(chooseButton)
        managementStack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: managementStack.widthAnchor).isActive = true
        addRow.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let addSeparator = separator()
        managementStack.addArrangedSubview(addSeparator)
        addSeparator.widthAnchor.constraint(equalTo: managementStack.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let rulesDocument = FlippedView()
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
        managementStack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: managementStack.widthAnchor).isActive = true
        root.addArrangedSubview(rulesBox)
        rulesBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        rulesBox.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let footer = wrappingLabel("智能模式仅在真正切换场景时降低音量；严格模式会持续执行上限。两种模式都不会自动调高音量。")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        return view
    }

    private func makeSwitch(action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.target = self
        control.action = action
        return control
    }

    private func makeSwitchRow(title: String, detail: String, control: NSSwitch) -> NSView {
        let row = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)
        row.addSubview(text)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 49),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeChoiceRow(title: String, detail: String, control: NSControl) -> NSView {
        let row = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 49),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 170)
        ])
        return row
    }

    private func makeLimitRow() -> NSView {
        let row = NSView()
        let title = NSTextField(labelWithString: "默认场景保护值")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: "未匹配规则时的系统音量上限")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        globalSlider.translatesAutoresizingMaskIntoConstraints = false
        globalValueLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(globalSlider)
        row.addSubview(globalValueLabel)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 62),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.widthAnchor.constraint(equalToConstant: 180),
            globalSlider.leadingAnchor.constraint(equalTo: labels.trailingAnchor, constant: 10),
            globalSlider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            globalValueLabel.leadingAnchor.constraint(equalTo: globalSlider.trailingAnchor, constant: 8),
            globalValueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            globalValueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            globalValueLabel.widthAnchor.constraint(equalToConstant: 44)
        ])
        return row
    }

    private func refreshAll() {
        let settings = settingsStore.settings
        protectionSwitch.state = settings.isProtectionEnabled ? .on : .off
        protectionModePopup.selectItem(at: ProtectionMode.allCases.firstIndex(of: settings.protectionMode) ?? 0)
        globalSlider.doubleValue = settings.defaultMaximumVolume
        globalValueLabel.stringValue = percent(settings.defaultMaximumVolume)
        loginSwitch.state = launchAtLoginManager.isEnabled ? .on : .off
        notificationSwitch.state = settings.notificationsEnabled ? .on : .off
        refreshStatus()
        refreshRunningApplications()
        rebuildRuleRows(settings.appRules)
        devicesView?.apply(snapshot: protectionController.currentAudioDevice, settings: settings)
        historyView?.apply(events: eventStore.events)
    }

    private func refreshStatus() {
        let status = protectionController.status
        let symbolName: String
        let tint: NSColor
        switch status.state {
        case .protecting:
            if status.isManualOverrideActive {
                statusTitleLabel.stringValue = "已保留手动音量"
                symbolName = "slider.horizontal.3"
                tint = .systemBlue
            } else {
                statusTitleLabel.stringValue = settingsStore.settings.protectionMode == .strict
                    ? "严格上限保护中"
                    : "智能场景保护中"
                symbolName = "checkmark.shield.fill"
                tint = .systemGreen
            }
        case let .paused(until):
            if let until = until {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                statusTitleLabel.stringValue = "已暂停，\(formatter.string(from: until)) 恢复"
            } else {
                statusTitleLabel.stringValue = "保护已暂停"
            }
            symbolName = "pause.circle.fill"
            tint = .systemOrange
        case .disabled:
            statusTitleLabel.stringValue = "保护已关闭"
            symbolName = "speaker.slash.circle.fill"
            tint = .secondaryLabelColor
        case .unsupported:
            statusTitleLabel.stringValue = "当前设备不支持系统音量"
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemOrange
        }
        if #available(macOS 11.0, *) {
            statusIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusTitleLabel.stringValue)
        }
        statusIconView.contentTintColor = tint
        let current = status.currentVolume.map(percent) ?? "--"
        statusDetailLabel.stringValue = "\(status.deviceName) · 当前 \(current)"
        if status.isManualOverrideActive {
            statusRuleLabel.stringValue = "下次场景切换保护到 \(percent(status.effectiveLimit.value)) · \(status.effectiveLimit.sourceName)"
        } else {
            statusRuleLabel.stringValue = "保护值 \(percent(status.effectiveLimit.value)) · \(status.effectiveLimit.sourceName)"
        }
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
            runningAppsPopup.addItem(withTitle: "没有可添加的运行中 App")
            runningAppsPopup.isEnabled = false
            addRunningAppButton.isEnabled = false
        } else {
            runningAppsPopup.addItems(withTitles: runningApplications.map { $0.localizedName ?? "未知 App" })
            runningAppsPopup.isEnabled = true
            addRunningAppButton.isEnabled = true
        }
    }

    private func rebuildRuleRows(_ rules: [AppVolumeRule]) {
        // Clear the live collection one item at a time. Mutating it from a
        // for-in loop can leave every second row visually stale even though
        // the rule has already been removed from persistent settings.
        while let view = rulesStack.arrangedSubviews.first {
            rulesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if rules.isEmpty {
            let empty = makeEmptyRulesView()
            rulesStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 154).isActive = true
            return
        }
        for rule in rules {
            let row = RuleRowView(rule: rule)
            row.onVolumeChanged = { [weak self] id, value in
                self?.updateRule(id: id, maximumVolume: value)
            }
            row.onEnabledChanged = { [weak self] id, enabled in
                self?.updateRule(id: id, isEnabled: enabled)
            }
            row.onRemove = { [weak self] id in
                self?.removeRule(id: id)
            }
            rulesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 64).isActive = true
        }
    }

    private func makeEmptyRulesView() -> NSView {
        let container = NSView()
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "app.badge.plus", accessibilityDescription: "添加 App 规则")
        }
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "尚未添加 App 规则")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        let detail = NSTextField(labelWithString: "从运行中的 App 添加，或在 Finder 中选择任意 App。")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Self.rulesToolbarIdentifier: selectedPane = .rules
        case Self.devicesToolbarIdentifier: selectedPane = .devices
        case Self.historyToolbarIdentifier: selectedPane = .history
        default: selectedPane = .general
        }
        showSelectedPane()
    }

    private func showSelectedPane() {
        guard hasBuiltWindow, let contentView = window?.contentView else { return }
        let paneView: NSView
        switch selectedPane {
        case .general: paneView = generalView
        case .rules: paneView = rulesView
        case .devices: paneView = devicesView
        case .history: paneView = historyView
        }
        for subview in contentView.subviews { subview.removeFromSuperview() }
        paneView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: contentView.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        window?.title = title(for: selectedPane)
        window?.toolbar?.selectedItemIdentifier = toolbarIdentifier(for: selectedPane)
        if selectedPane == .rules {
            refreshRunningApplications()
            rebuildRuleRows(settingsStore.settings.appRules)
        } else if selectedPane == .devices {
            devicesView.apply(
                snapshot: protectionController.currentAudioDevice,
                settings: settingsStore.settings
            )
        } else if selectedPane == .history {
            historyView.apply(events: eventStore.events)
        }
    }

    private func title(for pane: SettingsPane) -> String {
        switch pane {
        case .general: return "通用"
        case .rules: return "场景规则"
        case .devices: return "设备保护"
        case .history: return "保护历史"
        }
    }

    private func toolbarIdentifier(for pane: SettingsPane) -> NSToolbarItem.Identifier {
        switch pane {
        case .general: return Self.generalToolbarIdentifier
        case .rules: return Self.rulesToolbarIdentifier
        case .devices: return Self.devicesToolbarIdentifier
        case .history: return Self.historyToolbarIdentifier
        }
    }

    private func releaseWindowResources() {
        window = nil
        hasBuiltWindow = false
        generalView = nil
        rulesView = nil
        devicesView = nil
        historyView = nil
        protectionSwitch = nil
        protectionModePopup = nil
        globalSlider = nil
        globalValueLabel = nil
        loginSwitch = nil
        notificationSwitch = nil
        statusIconView = nil
        statusTitleLabel = nil
        statusDetailLabel = nil
        statusRuleLabel = nil
        runningAppsPopup = nil
        addRunningAppButton = nil
        rulesStack = nil
        runningApplications.removeAll(keepingCapacity: false)
    }

    @objc private func protectionChanged() {
        performSettingsUpdate { $0.isProtectionEnabled = protectionSwitch.state == .on }
    }

    @objc private func protectionModeChanged() {
        let index = protectionModePopup.indexOfSelectedItem
        guard ProtectionMode.allCases.indices.contains(index) else { return }
        performSettingsUpdate { $0.protectionMode = ProtectionMode.allCases[index] }
        refreshStatus()
    }

    @objc private func globalLimitChanged() {
        let value = globalSlider.doubleValue
        globalValueLabel.stringValue = percent(value)
        performSettingsUpdate { $0.defaultMaximumVolume = value }
    }

    @objc private func loginChanged() {
        let shouldEnable = loginSwitch.state == .on
        do {
            try launchAtLoginManager.setEnabled(shouldEnable)
            performSettingsUpdate { $0.launchAtLogin = shouldEnable }
        } catch {
            loginSwitch.state = launchAtLoginManager.isEnabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    @objc private func notificationChanged() {
        performSettingsUpdate { $0.notificationsEnabled = notificationSwitch.state == .on }
    }

    @objc private func addRunningAppRule() {
        let index = runningAppsPopup.indexOfSelectedItem
        guard runningApplications.indices.contains(index),
              let bundleID = runningApplications[index].bundleIdentifier else { return }
        let app = runningApplications[index]
        addRule(bundleIdentifier: bundleID, appName: app.localizedName ?? bundleID)
    }

    @objc private func chooseInstalledApp() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要设置保护音量的 App"
        panel.prompt = "选择"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法读取这个 App"
                alert.informativeText = "请选择包含有效 Bundle Identifier 的 macOS App。"
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }
            self?.addRule(
                bundleIdentifier: bundleID,
                appName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
            )
        }
    }

    private func addRule(bundleIdentifier: String, appName: String) {
        guard !settingsStore.settings.appRules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            NSSound.beep()
            return
        }
        performSettingsUpdate {
            $0.appRules.append(AppVolumeRule(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                maximumVolume: $0.defaultMaximumVolume
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

    private func updateRule(id: UUID, isEnabled: Bool) {
        performSettingsUpdate { settings in
            guard let index = settings.appRules.firstIndex(where: { $0.id == id }) else { return }
            settings.appRules[index].isEnabled = isEnabled
        }
    }

    private func removeRule(id: UUID) {
        performSettingsUpdate { $0.appRules.removeAll { $0.id == id } }
        refreshAll()
    }

    private func updateDeviceRule(
        snapshot: AudioDeviceSnapshot,
        enabled: Bool,
        maximumVolume: Double
    ) {
        performSettingsUpdate { settings in
            if let index = settings.deviceRules.firstIndex(where: {
                $0.deviceIdentifier == snapshot.deviceIdentifier
            }) {
                settings.deviceRules[index].isEnabled = enabled
                settings.deviceRules[index].maximumVolume = maximumVolume
                settings.deviceRules[index].deviceName = snapshot.deviceName
            } else if enabled {
                settings.deviceRules.append(DeviceVolumeRule(
                    deviceIdentifier: snapshot.deviceIdentifier,
                    deviceName: snapshot.deviceName,
                    maximumVolume: maximumVolume
                ))
            }
        }
    }

    private func updateTypePreset(
        category: AudioDeviceCategory,
        enabled: Bool,
        maximumVolume: Double
    ) {
        performSettingsUpdate { settings in
            if let index = settings.deviceTypePresets.firstIndex(where: { $0.category == category }) {
                settings.deviceTypePresets[index].isEnabled = enabled
                settings.deviceTypePresets[index].maximumVolume = maximumVolume
            } else {
                settings.deviceTypePresets.append(DeviceTypePreset(
                    category: category,
                    maximumVolume: maximumVolume,
                    isEnabled: enabled
                ))
            }
        }
    }

    private func performSettingsUpdate(_ mutation: (inout GuardSettings) -> Void) {
        isPerformingUpdate = true
        settingsStore.update(mutation)
        isPerformingUpdate = false
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeGroupBox() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.isTransparent = false
        box.cornerRadius = 8
        return box
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class RuleRowView: NSView {
    var onVolumeChanged: ((UUID, Double) -> Void)?
    var onEnabledChanged: ((UUID, Bool) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private let ruleID: UUID
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let enabledSwitch: NSSwitch
    private let removeButton: NSButton

    init(rule: AppVolumeRule) {
        ruleID = rule.id
        slider = NSSlider(value: rule.maximumVolume, minValue: 0.05, maxValue: 1.00, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "\(Int((rule.maximumVolume * 100).rounded()))%")
        enabledSwitch = NSSwitch()
        removeButton = NSButton(title: "移除", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let appName = NSTextField(labelWithString: rule.appName)
        appName.font = .systemFont(ofSize: 13, weight: .medium)
        appName.lineBreakMode = .byTruncatingTail
        let bundleID = NSTextField(labelWithString: rule.bundleIdentifier)
        bundleID.font = .systemFont(ofSize: 10)
        bundleID.textColor = .secondaryLabelColor
        bundleID.lineBreakMode = .byTruncatingMiddle
        let appStack = NSStackView(views: [appName, bundleID])
        appStack.orientation = .vertical
        appStack.alignment = .leading
        appStack.spacing = 2
        appStack.translatesAutoresizingMaskIntoConstraints = false

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel("\(rule.appName) 保护音量")
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.controlSize = .small
        enabledSwitch.state = rule.isEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged)
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.setAccessibilityLabel("启用 \(rule.appName) 规则")

        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.isEnabled = true
        removeButton.setAccessibilityLabel("移除 \(rule.appName) 规则")
        if #available(macOS 11.0, *) {
            removeButton.hasDestructiveAction = true
        }
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(appStack)
        addSubview(slider)
        addSubview(valueLabel)
        addSubview(enabledSwitch)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            appStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            appStack.widthAnchor.constraint(equalToConstant: 155),
            slider.leadingAnchor.constraint(equalTo: appStack.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueLabel.widthAnchor.constraint(equalToConstant: 42),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            enabledSwitch.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 10),
            enabledSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: enabledSwitch.trailingAnchor, constant: 8),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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
        updateEnabledAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sliderChanged() {
        valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        onVolumeChanged?(ruleID, slider.doubleValue)
    }

    @objc private func enabledChanged() {
        updateEnabledAppearance()
        onEnabledChanged?(ruleID, enabledSwitch.state == .on)
    }

    @objc private func removeTapped() {
        onRemove?(ruleID)
    }

    func performRemoveForTesting() {
        removeButton.performClick(nil)
    }

    private func updateEnabledAppearance() {
        let enabled = enabledSwitch.state == .on
        slider.isEnabled = enabled
        valueLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
    }
}
