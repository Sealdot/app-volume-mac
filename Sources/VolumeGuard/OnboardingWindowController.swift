import AppKit
import VolumeGuardCore

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let onCompletion: () -> Void
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(settingsStore: SettingsStore, onCompletion: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.onCompletion = onCompletion
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadWindow() {
        let onboardingWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 620, height: 430)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        onboardingWindow.title = "欢迎使用音量卫士"
        onboardingWindow.center()
        onboardingWindow.delegate = self
        window = onboardingWindow

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        onboardingWindow.contentView?.addSubview(root)
        guard let content = onboardingWindow.contentView else { return }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        let heading = NSTextField(labelWithString: "先建立一道安静、可解释的音量护栏")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        root.addArrangedSubview(heading)
        let subtitle = NSTextField(wrappingLabelWithString: "默认保护值为 20%。音量卫士只读取系统音量和当前前台 App，不录音、不安装虚拟音频设备，也不联网。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 10
        cards.distribution = .fillEqually
        cards.addArrangedSubview(featureCard(
            symbol: "rectangle.on.rectangle",
            title: "场景发生变化时",
            detail: "启动、切换前台 App、输出设备或睡眠唤醒时，只在超限时调低。"
        ))
        cards.addArrangedSubview(featureCard(
            symbol: "hand.raised.fill",
            title: "尊重你的选择",
            detail: "智能模式保留之后的手动调节；严格模式会持续执行上限。"
        ))
        cards.addArrangedSubview(featureCard(
            symbol: "headphones",
            title: "耳机离开保护",
            detail: "从耳机切到扬声器时，可立即静音或降至指定音量。"
        ))
        root.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        cards.heightAnchor.constraint(equalToConstant: 132).isActive = true

        modePopup.addItems(withTitles: ProtectionMode.allCases.map { $0.displayName })
        modePopup.target = self
        modePopup.action = #selector(selectionChanged)
        styleChoicePopup(modePopup)
        modePopup.selectItem(at: ProtectionMode.allCases.firstIndex(of: settingsStore.settings.protectionMode) ?? 0)
        modePopup.setAccessibilityLabel("保护模式")
        root.addArrangedSubview(choiceRow(
            title: "保护模式",
            detail: "推荐智能场景保护，日常调音量不会被立刻抢回",
            control: modePopup
        ))

        headphonePopup.addItems(withTitles: HeadphoneExitAction.allCases.map { $0.displayName })
        headphonePopup.target = self
        headphonePopup.action = #selector(selectionChanged)
        styleChoicePopup(headphonePopup)
        headphonePopup.selectItem(
            at: HeadphoneExitAction.allCases.firstIndex(of: settingsStore.settings.headphoneExitAction) ?? 0
        )
        headphonePopup.setAccessibilityLabel("耳机离开动作")
        root.addArrangedSubview(choiceRow(
            title: "耳机离开",
            detail: "推荐立即静音；不支持静音的设备会回退为降低音量",
            control: headphonePopup
        ))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        let note = NSTextField(labelWithString: "稍后可在“设备”中设置逐设备值和类型预设")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let startButton = NSButton(title: "开始保护", target: self, action: #selector(finishOnboarding))
        startButton.setButtonType(.momentaryPushIn)
        startButton.isBordered = false
        startButton.controlSize = .regular
        startButton.isEnabled = true
        startButton.attributedTitle = NSAttributedString(
            string: "开始保护  →",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemTeal
            ]
        )
        startButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(note)
        buttons.addArrangedSubview(startButton)
        root.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    @discardableResult
    func writeSnapshot(to url: URL) -> Bool {
        guard let view = window?.contentView else { return false }
        window?.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @objc private func finishOnboarding() {
        let modeIndex = modePopup.indexOfSelectedItem
        let actionIndex = headphonePopup.indexOfSelectedItem
        settingsStore.update { settings in
            if ProtectionMode.allCases.indices.contains(modeIndex) {
                settings.protectionMode = ProtectionMode.allCases[modeIndex]
            }
            if HeadphoneExitAction.allCases.indices.contains(actionIndex) {
                settings.headphoneExitAction = HeadphoneExitAction.allCases[actionIndex]
            }
            settings.hasCompletedOnboarding = true
        }
        close()
        onCompletion()
    }

    @objc private func selectionChanged() {}

    private func styleChoicePopup(_ popup: NSPopUpButton) {
        popup.isBordered = false
        popup.font = .systemFont(ofSize: 12, weight: .medium)
        popup.contentTintColor = .controlTextColor
    }

    private func featureCard(symbol: String, title: String, detail: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 8
        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        icon.contentTintColor = .systemTeal
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -8),
                detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        return box
    }

    private func choiceRow(title: String, detail: String, control: NSControl) -> NSView {
        let row = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
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
            row.heightAnchor.constraint(equalToConstant: 38),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 170)
        ])
        return row
    }
}
