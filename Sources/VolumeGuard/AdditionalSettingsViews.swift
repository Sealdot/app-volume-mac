import AppKit
import VolumeGuardCore

final class DevicesSettingsView: NSView {
    private let onDeviceRuleChanged: (AudioDeviceSnapshot, Bool, Double) -> Void
    private let onHeadphoneActionChanged: (HeadphoneExitAction) -> Void
    private let onHeadphoneVolumeChanged: (Double) -> Void
    private let onTypePresetChanged: (AudioDeviceCategory, Bool, Double) -> Void

    private let deviceIcon = NSImageView()
    private let deviceNameLabel = NSTextField(labelWithString: "正在检测…")
    private let deviceDetailLabel = NSTextField(labelWithString: "")
    private let compatibilityLabel = NSTextField(labelWithString: "")
    private let deviceRuleSwitch = NSSwitch()
    private let deviceRuleSlider = NSSlider(value: 0.20, minValue: 0.05, maxValue: 1.0, target: nil, action: nil)
    private let deviceRuleValue = NSTextField(labelWithString: "20%")
    private let headphoneActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headphoneVolumeSlider = NSSlider(value: 0.20, minValue: 0.05, maxValue: 1.0, target: nil, action: nil)
    private let headphoneVolumeValue = NSTextField(labelWithString: "20%")
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typePresetSwitch = NSSwitch()
    private let typePresetSlider = NSSlider(value: 0.20, minValue: 0.05, maxValue: 1.0, target: nil, action: nil)
    private let typePresetValue = NSTextField(labelWithString: "20%")

    private var snapshot: AudioDeviceSnapshot?
    private var settings = GuardSettings()
    private var isRefreshing = false

    init(
        onDeviceRuleChanged: @escaping (AudioDeviceSnapshot, Bool, Double) -> Void,
        onHeadphoneActionChanged: @escaping (HeadphoneExitAction) -> Void,
        onHeadphoneVolumeChanged: @escaping (Double) -> Void,
        onTypePresetChanged: @escaping (AudioDeviceCategory, Bool, Double) -> Void
    ) {
        self.onDeviceRuleChanged = onDeviceRuleChanged
        self.onHeadphoneActionChanged = onHeadphoneActionChanged
        self.onHeadphoneVolumeChanged = onHeadphoneVolumeChanged
        self.onTypePresetChanged = onTypePresetChanged
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(snapshot: AudioDeviceSnapshot, settings: GuardSettings) {
        isRefreshing = true
        self.snapshot = snapshot
        self.settings = settings

        deviceNameLabel.stringValue = snapshot.deviceName
        deviceDetailLabel.stringValue = "\(snapshot.category.displayName) · \(snapshot.deviceIdentifier)"
        let symbolName: String
        if snapshot.canSetVolume && snapshot.canSetMute {
            compatibilityLabel.stringValue = "完整支持：可调系统音量与静音"
            compatibilityLabel.textColor = .systemGreen
            symbolName = "checkmark.circle.fill"
        } else if snapshot.canSetVolume {
            compatibilityLabel.stringValue = "部分支持：可调音量，静音不可用时自动回退"
            compatibilityLabel.textColor = .systemOrange
            symbolName = "exclamationmark.circle.fill"
        } else {
            compatibilityLabel.stringValue = "不支持：该设备没有可写的系统音量"
            compatibilityLabel.textColor = .systemOrange
            symbolName = "exclamationmark.triangle.fill"
        }
        if #available(macOS 11.0, *) {
            deviceIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "设备兼容性")
        }
        deviceIcon.contentTintColor = compatibilityLabel.textColor

        let rule = settings.deviceRules.last(where: {
            $0.deviceIdentifier == snapshot.deviceIdentifier
        })
        deviceRuleSwitch.state = rule?.isEnabled == true ? .on : .off
        deviceRuleSwitch.isEnabled = snapshot.canSetVolume
        deviceRuleSlider.doubleValue = rule?.maximumVolume ?? settings.defaultMaximumVolume
        deviceRuleSlider.isEnabled = snapshot.canSetVolume && deviceRuleSwitch.state == .on
        deviceRuleValue.stringValue = percent(deviceRuleSlider.doubleValue)

        headphoneActionPopup.selectItem(
            at: HeadphoneExitAction.allCases.firstIndex(of: settings.headphoneExitAction) ?? 0
        )
        headphoneVolumeSlider.doubleValue = settings.headphoneExitVolume
        headphoneVolumeSlider.isEnabled = settings.headphoneExitAction != .doNothing
        headphoneVolumeValue.stringValue = percent(settings.headphoneExitVolume)

        applySelectedTypePreset()
        isRefreshing = false
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])

        root.addArrangedSubview(sectionTitle("当前输出与兼容性"))
        let compatibilityBox = groupBox()
        let compatibilityContent = NSStackView()
        compatibilityContent.orientation = .horizontal
        compatibilityContent.alignment = .centerY
        compatibilityContent.spacing = 12
        compatibilityContent.translatesAutoresizingMaskIntoConstraints = false
        deviceIcon.translatesAutoresizingMaskIntoConstraints = false
        deviceIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        deviceIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        deviceNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        deviceDetailLabel.font = .systemFont(ofSize: 10)
        deviceDetailLabel.textColor = .tertiaryLabelColor
        deviceDetailLabel.lineBreakMode = .byTruncatingMiddle
        compatibilityLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let deviceText = NSStackView(views: [deviceNameLabel, compatibilityLabel, deviceDetailLabel])
        deviceText.orientation = .vertical
        deviceText.alignment = .leading
        deviceText.spacing = 2
        compatibilityContent.addArrangedSubview(deviceIcon)
        compatibilityContent.addArrangedSubview(deviceText)
        pin(compatibilityContent, in: compatibilityBox, horizontal: 12, vertical: 8)
        root.addArrangedSubview(compatibilityBox)
        compatibilityBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        compatibilityBox.heightAnchor.constraint(equalToConstant: 82).isActive = true

        root.addArrangedSubview(sectionTitle("当前设备规则"))
        configureSwitch(deviceRuleSwitch, action: #selector(deviceRuleToggled))
        configureSlider(deviceRuleSlider, action: #selector(deviceRuleSliderChanged), label: "当前设备保护值")
        configureValueLabel(deviceRuleValue)
        let deviceRuleBox = groupBox()
        let deviceRuleRow = valueRow(
            title: "为当前设备使用独立保护值",
            detail: "前台场景规则存在时仍以场景规则为准",
            toggle: deviceRuleSwitch,
            slider: deviceRuleSlider,
            value: deviceRuleValue
        )
        pin(deviceRuleRow, in: deviceRuleBox, horizontal: 12, vertical: 6)
        root.addArrangedSubview(deviceRuleBox)
        deviceRuleBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        deviceRuleBox.heightAnchor.constraint(equalToConstant: 84).isActive = true

        root.addArrangedSubview(sectionTitle("耳机离开保护"))
        headphoneActionPopup.addItems(withTitles: HeadphoneExitAction.allCases.map { $0.displayName })
        headphoneActionPopup.target = self
        headphoneActionPopup.action = #selector(headphoneActionChanged)
        headphoneActionPopup.setAccessibilityLabel("从耳机切换后的动作")
        configureSlider(headphoneVolumeSlider, action: #selector(headphoneVolumeChanged), label: "耳机离开回退音量")
        configureValueLabel(headphoneVolumeValue)
        let headphoneBox = groupBox()
        let headphoneContent = twoLineControl(
            firstTitle: "从耳机切换到其他输出时",
            firstControl: headphoneActionPopup,
            secondTitle: "降音量或静音不可用时回退到",
            slider: headphoneVolumeSlider,
            value: headphoneVolumeValue
        )
        pin(headphoneContent, in: headphoneBox, horizontal: 12, vertical: 6)
        root.addArrangedSubview(headphoneBox)
        headphoneBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        headphoneBox.heightAnchor.constraint(equalToConstant: 94).isActive = true

        root.addArrangedSubview(sectionTitle("设备类型预设"))
        typePopup.addItems(withTitles: AudioDeviceCategory.allCases.map { $0.displayName })
        typePopup.target = self
        typePopup.action = #selector(typeSelectionChanged)
        typePopup.setAccessibilityLabel("设备类型")
        configureSwitch(typePresetSwitch, action: #selector(typePresetToggled))
        configureSlider(typePresetSlider, action: #selector(typePresetSliderChanged), label: "设备类型保护值")
        configureValueLabel(typePresetValue)
        let typeBox = groupBox()
        let typeContent = typePresetContent()
        pin(typeContent, in: typeBox, horizontal: 12, vertical: 6)
        root.addArrangedSubview(typeBox)
        typeBox.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        typeBox.heightAnchor.constraint(equalToConstant: 94).isActive = true

        let footer = NSTextField(wrappingLabelWithString: "设备类型由 Core Audio 与设备名称在本机推断，可随时调整。所有数值都是系统音量百分比，不代表真实 dB 或声压。")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func valueRow(
        title: String,
        detail: String,
        toggle: NSSwitch,
        slider: NSSlider,
        value: NSTextField
    ) -> NSView {
        let container = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        [labels, toggle, slider, value].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; container.addSubview($0) }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -8),
            slider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            value.widthAnchor.constraint(equalToConstant: 44)
        ])
        return container
    }

    private func twoLineControl(
        firstTitle: String,
        firstControl: NSControl,
        secondTitle: String,
        slider: NSSlider,
        value: NSTextField
    ) -> NSView {
        let container = NSView()
        let firstLabel = NSTextField(labelWithString: firstTitle)
        firstLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let secondLabel = NSTextField(labelWithString: secondTitle)
        secondLabel.font = .systemFont(ofSize: 11)
        secondLabel.textColor = .secondaryLabelColor
        [firstLabel, firstControl, secondLabel, slider, value].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            firstLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            firstLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            firstControl.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            firstControl.centerYAnchor.constraint(equalTo: firstLabel.centerYAnchor),
            firstControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            secondLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            secondLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            secondLabel.widthAnchor.constraint(equalToConstant: 215),
            slider.leadingAnchor.constraint(equalTo: secondLabel.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -8),
            slider.centerYAnchor.constraint(equalTo: secondLabel.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            value.widthAnchor.constraint(equalToConstant: 44)
        ])
        return container
    }

    private func typePresetContent() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "类型")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let enabled = NSTextField(labelWithString: "启用此类型预设")
        enabled.font = .systemFont(ofSize: 11)
        enabled.textColor = .secondaryLabelColor
        [title, typePopup, enabled, typePresetSwitch, typePresetSlider, typePresetValue].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            typePopup.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            typePopup.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            typePopup.widthAnchor.constraint(equalToConstant: 150),
            enabled.leadingAnchor.constraint(equalTo: typePopup.trailingAnchor, constant: 20),
            enabled.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            typePresetSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            typePresetSwitch.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            typePresetSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            typePresetSlider.trailingAnchor.constraint(equalTo: typePresetValue.leadingAnchor, constant: -8),
            typePresetSlider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            typePresetValue.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            typePresetValue.centerYAnchor.constraint(equalTo: typePresetSlider.centerYAnchor),
            typePresetValue.widthAnchor.constraint(equalToConstant: 44)
        ])
        return container
    }

    private func applySelectedTypePreset() {
        let index = max(0, typePopup.indexOfSelectedItem)
        let category = AudioDeviceCategory.allCases.indices.contains(index)
            ? AudioDeviceCategory.allCases[index]
            : .other
        let preset = settings.deviceTypePresets.first(where: { $0.category == category })
            ?? DeviceTypePreset.recommendedDefaults.first(where: { $0.category == category })
            ?? DeviceTypePreset(category: category, maximumVolume: 0.20, isEnabled: false)
        typePresetSwitch.state = preset.isEnabled ? .on : .off
        typePresetSlider.doubleValue = preset.maximumVolume
        typePresetSlider.isEnabled = preset.isEnabled
        typePresetValue.stringValue = percent(preset.maximumVolume)
    }

    private func selectedCategory() -> AudioDeviceCategory? {
        let index = typePopup.indexOfSelectedItem
        guard AudioDeviceCategory.allCases.indices.contains(index) else { return nil }
        return AudioDeviceCategory.allCases[index]
    }

    @objc private func deviceRuleToggled() {
        guard !isRefreshing, let snapshot = snapshot else { return }
        deviceRuleSlider.isEnabled = deviceRuleSwitch.state == .on && snapshot.canSetVolume
        onDeviceRuleChanged(snapshot, deviceRuleSwitch.state == .on, deviceRuleSlider.doubleValue)
    }

    @objc private func deviceRuleSliderChanged() {
        deviceRuleValue.stringValue = percent(deviceRuleSlider.doubleValue)
        guard !isRefreshing, let snapshot = snapshot else { return }
        onDeviceRuleChanged(snapshot, true, deviceRuleSlider.doubleValue)
    }

    @objc private func headphoneActionChanged() {
        guard !isRefreshing else { return }
        let index = headphoneActionPopup.indexOfSelectedItem
        guard HeadphoneExitAction.allCases.indices.contains(index) else { return }
        let action = HeadphoneExitAction.allCases[index]
        headphoneVolumeSlider.isEnabled = action != .doNothing
        onHeadphoneActionChanged(action)
    }

    @objc private func headphoneVolumeChanged() {
        headphoneVolumeValue.stringValue = percent(headphoneVolumeSlider.doubleValue)
        guard !isRefreshing else { return }
        onHeadphoneVolumeChanged(headphoneVolumeSlider.doubleValue)
    }

    @objc private func typeSelectionChanged() {
        guard !isRefreshing else { return }
        isRefreshing = true
        applySelectedTypePreset()
        isRefreshing = false
    }

    @objc private func typePresetToggled() {
        guard !isRefreshing, let category = selectedCategory() else { return }
        let enabled = typePresetSwitch.state == .on
        typePresetSlider.isEnabled = enabled
        onTypePresetChanged(category, enabled, typePresetSlider.doubleValue)
        settings.deviceTypePresets.removeAll { $0.category == category }
        settings.deviceTypePresets.append(DeviceTypePreset(
            category: category,
            maximumVolume: typePresetSlider.doubleValue,
            isEnabled: enabled
        ))
    }

    @objc private func typePresetSliderChanged() {
        typePresetValue.stringValue = percent(typePresetSlider.doubleValue)
        guard !isRefreshing, let category = selectedCategory() else { return }
        onTypePresetChanged(category, true, typePresetSlider.doubleValue)
        settings.deviceTypePresets.removeAll { $0.category == category }
        settings.deviceTypePresets.append(DeviceTypePreset(
            category: category,
            maximumVolume: typePresetSlider.doubleValue,
            isEnabled: true
        ))
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.controlSize = .small
        control.target = self
        control.action = action
    }

    private func configureSlider(_ control: NSSlider, action: Selector, label: String) {
        control.isContinuous = true
        control.target = self
        control.action = action
        control.setAccessibilityLabel(label)
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func groupBox() -> NSBox {
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

    private func pin(_ view: NSView, in box: NSBox, horizontal: CGFloat, vertical: CGFloat) {
        guard let content = box.contentView else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -vertical)
        ])
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

final class HistorySettingsView: NSView {
    private let onClear: () -> Void
    private let eventsStack = NSStackView()
    private let clearButton = NSButton(title: "清除历史", target: nil, action: nil)

    init(onClear: @escaping () -> Void) {
        self.onClear = onClear
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(events: [ProtectionEvent]) {
        while let view = eventsStack.arrangedSubviews.first {
            eventsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        clearButton.isEnabled = !events.isEmpty
        if events.isEmpty {
            let empty = NSTextField(labelWithString: "还没有保护事件")
            empty.font = .systemFont(ofSize: 14, weight: .medium)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            eventsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: eventsStack.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 300).isActive = true
            return
        }
        for event in events {
            let row = historyRow(event)
            eventsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: eventsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 58).isActive = true
        }
    }

    private func buildUI() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        let title = NSTextField(labelWithString: "最近 20 次保护")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.isBordered = false
        clearButton.controlSize = .small
        clearButton.attributedTitle = NSAttributedString(
            string: "清除历史",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.systemTeal
            ]
        )
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(clearButton)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let document = AdditionalFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        eventsStack.orientation = .vertical
        eventsStack.alignment = .leading
        eventsStack.spacing = 0
        eventsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(eventsStack)

        let footer = NSTextField(wrappingLabelWithString: "历史仅保存在本机，记录发生时间、场景、输出设备和保护结果；不会记录或上传音频内容。")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            eventsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            eventsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            eventsStack.topAnchor.constraint(equalTo: document.topAnchor),
            eventsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    private func historyRow(_ event: ProtectionEvent) -> NSView {
        let row = NSView()
        let icon = NSImageView()
        let title: String
        let detail: String
        let symbol: String
        switch event.kind {
        case .volumeReduced:
            title = String(
                format: "%@ · %d%% → %d%%",
                event.appName,
                Int((event.previousVolume * 100).rounded()),
                Int((event.adjustedVolume * 100).rounded())
            )
            detail = "\(event.deviceName) · \(event.ruleName)"
            symbol = "speaker.wave.1.fill"
        case .headphoneExitMuted:
            title = "耳机离开后已静音"
            detail = event.deviceName
            symbol = "speaker.slash.fill"
        case .headphoneExitReduced:
            title = String(
                format: "耳机离开 · %d%% → %d%%",
                Int((event.previousVolume * 100).rounded()),
                Int((event.adjustedVolume * 100).rounded())
            )
            detail = event.deviceName
            symbol = "headphones"
        }
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        icon.contentTintColor = .systemTeal
        icon.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let dateLabel = NSTextField(labelWithString: formatter.string(from: event.date))
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(labels)
        row.addSubview(dateLabel)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            dateLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    @objc private func clearHistory() {
        onClear()
    }
}

private final class AdditionalFlippedView: NSView {
    override var isFlipped: Bool { true }
}
