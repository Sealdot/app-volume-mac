import AppKit
import Foundation
import UserNotifications
import VolumeGuardCore

enum GuardRuntimeState: Equatable {
    case protecting
    case paused(until: Date?)
    case disabled
    case unsupported
}

struct GuardRuntimeStatus: Equatable {
    var state: GuardRuntimeState
    var currentVolume: Double?
    var effectiveLimit: VolumeLimit
    var deviceName: String
    var foregroundAppName: String
    var foregroundBundleIdentifier: String?
    var isManualOverrideActive: Bool
    var lastError: String?
}

final class ProtectionController {
    static let didChangeNotification = Notification.Name("VolumeGuard.ProtectionStatusDidChange")

    var onStatusChange: ((GuardRuntimeStatus) -> Void)?
    var onProtectionEvent: ((ProtectionEvent) -> Void)?

    private let settingsStore: SettingsStore
    private let eventStore: ProtectionEventStore
    private let audioController: SystemAudioController
    private var observers: [NSObjectProtocol] = []
    private var lastExternalApplication: NSRunningApplication?
    private var isPaused = false
    private var pauseUntil: Date?
    private var pauseTimer: Timer?
    private var evaluationScheduled = false
    private var pendingTrigger: ProtectionTrigger?
    private var lastProtectionContext: ProtectionContext?
    private var lastAudioSnapshot: AudioDeviceSnapshot?
    private var lastNotificationDate = Date.distantPast

    private struct ProtectionContext: Equatable {
        let foregroundBundleIdentifier: String?
        let outputDeviceIdentifier: String
        let outputDeviceCategory: AudioDeviceCategory
    }

    private(set) var status: GuardRuntimeStatus

    var currentAudioDevice: AudioDeviceSnapshot {
        audioController.snapshot()
    }

    init(
        settingsStore: SettingsStore,
        eventStore: ProtectionEventStore,
        audioController: SystemAudioController
    ) {
        self.settingsStore = settingsStore
        self.eventStore = eventStore
        self.audioController = audioController
        let limit = VolumePolicy.effectiveLimit(
            settings: settingsStore.settings,
            foregroundBundleIdentifier: nil
        )
        self.status = GuardRuntimeStatus(
            state: settingsStore.settings.isProtectionEnabled ? .protecting : .disabled,
            currentVolume: nil,
            effectiveLimit: limit,
            deviceName: "正在检测…",
            foregroundAppName: "无",
            foregroundBundleIdentifier: nil,
            isManualOverrideActive: false,
            lastError: nil
        )
    }

    deinit {
        stop()
    }

    func start() {
        refreshForegroundApplication()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleEvaluation(trigger: .settingsChanged)
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleApplicationActivation(notification)
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.audioController.rebindMonitoring()
        })

        audioController.startMonitoring { [weak self] reason in
            switch reason {
            case .volumeOrMute:
                self?.scheduleEvaluation(trigger: .volumeChanged)
            case .outputDevice:
                self?.scheduleEvaluation(trigger: .outputDeviceChanged)
            case .systemWake:
                self?.scheduleEvaluation(trigger: .systemWake)
            }
        }
        evaluateNow(trigger: .startup)
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pauseTimer?.invalidate()
        pauseTimer = nil
        audioController.stopMonitoring()
    }

    func pause(for interval: TimeInterval?) {
        isPaused = true
        pauseUntil = interval.map { Date().addingTimeInterval($0) }
        configurePauseTimer()
        evaluateNow(trigger: .manualCheck)
    }

    func resume() {
        isPaused = false
        pauseUntil = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        evaluateNow(trigger: .resumed)
    }

    private func evaluateNow(trigger: ProtectionTrigger) {
        refreshForegroundApplication()

        if let until = pauseUntil, until <= Date() {
            isPaused = false
            pauseUntil = nil
            pauseTimer?.invalidate()
            pauseTimer = nil
        }

        let settings = settingsStore.settings
        let app = lastExternalApplication
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName ?? "无"
        let snapshot = audioController.snapshot()
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: bundleID,
            outputDeviceIdentifier: snapshot.deviceIdentifier,
            outputDeviceCategory: snapshot.category
        )
        let context = ProtectionContext(
            foregroundBundleIdentifier: bundleID,
            outputDeviceIdentifier: snapshot.deviceIdentifier,
            outputDeviceCategory: snapshot.category
        )
        let contextDidChange = lastProtectionContext.map { $0 != context } ?? true
        let effectiveTrigger = trigger.resolvingContextChange(contextDidChange)
        lastProtectionContext = context

        var nextState: GuardRuntimeState
        if !settings.isProtectionEnabled {
            nextState = .disabled
        } else if isPaused {
            nextState = .paused(until: pauseUntil)
        } else if !snapshot.canSetVolume {
            nextState = .unsupported
        } else {
            nextState = .protecting
        }

        var lastError: String?
        var displayedVolume = snapshot.volume
        let headphoneExitResult = applyHeadphoneExitProtectionIfNeeded(
            previousSnapshot: lastAudioSnapshot,
            currentSnapshot: snapshot,
            settings: settings,
            limit: limit,
            appName: appName,
            isPaused: isPaused
        )
        lastAudioSnapshot = snapshot
        if let result = headphoneExitResult {
            displayedVolume = result.displayedVolume
            lastError = result.errorMessage
            if result.errorMessage != nil && !snapshot.canSetVolume {
                nextState = .unsupported
            }
        } else if let volume = snapshot.volume,
           snapshot.canSetVolume,
           let decision = VolumePolicy.clampDecision(
               currentVolume: volume,
               settings: settings,
               foregroundBundleIdentifier: bundleID,
               outputDeviceIdentifier: snapshot.deviceIdentifier,
               outputDeviceCategory: snapshot.category,
               isPaused: isPaused,
               trigger: effectiveTrigger
           ) {
            do {
                try audioController.setVolume(decision.targetVolume)
                let event = ProtectionEvent(
                    appName: appName,
                    deviceName: snapshot.deviceName,
                    previousVolume: decision.previousVolume,
                    adjustedVolume: decision.targetVolume,
                    ruleName: decision.limit.sourceName
                )
                record(event: event, settings: settings)
                displayedVolume = decision.targetVolume
            } catch {
                lastError = error.localizedDescription
                nextState = .unsupported
            }
        }

        status = GuardRuntimeStatus(
            state: nextState,
            currentVolume: displayedVolume,
            effectiveLimit: limit,
            deviceName: snapshot.deviceName,
            foregroundAppName: appName,
            foregroundBundleIdentifier: bundleID,
            isManualOverrideActive: nextState == .protecting
                && !effectiveTrigger.shouldEnforceLimit(in: settings.protectionMode)
                && (snapshot.volume ?? 0) > limit.value + 0.005,
            lastError: lastError
        )
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        onStatusChange?(status)
    }

    private struct HeadphoneExitResult {
        let displayedVolume: Double?
        let errorMessage: String?
    }

    private func applyHeadphoneExitProtectionIfNeeded(
        previousSnapshot: AudioDeviceSnapshot?,
        currentSnapshot: AudioDeviceSnapshot,
        settings: GuardSettings,
        limit: VolumeLimit,
        appName: String,
        isPaused: Bool
    ) -> HeadphoneExitResult? {
        let originalVolume = currentSnapshot.volume ?? 0
        let contextDidChange = previousSnapshot.map {
            $0.deviceIdentifier != currentSnapshot.deviceIdentifier
                || $0.category != currentSnapshot.category
        } ?? false
        guard let decision = VolumePolicy.headphoneExitDecision(
                  settings: settings,
                  previousCategory: previousSnapshot?.category,
                  currentCategory: currentSnapshot.category,
                  contextDidChange: contextDidChange,
                  isPaused: isPaused,
                  currentVolume: originalVolume,
                  effectiveLimit: limit.value,
                  canSetVolume: currentSnapshot.canSetVolume,
                  canSetMute: currentSnapshot.canSetMute
              ) else { return nil }

        switch decision {
        case let .mute(adjustedVolume):
            do {
                try audioController.setMuted(true)
            } catch {
                guard currentSnapshot.canSetVolume else {
                    return HeadphoneExitResult(
                        displayedVolume: currentSnapshot.volume,
                        errorMessage: error.localizedDescription
                    )
                }
                return reduceAfterHeadphoneExit(
                    currentSnapshot: currentSnapshot,
                    settings: settings,
                    limit: limit,
                    appName: appName,
                    originalVolume: originalVolume
                )
            }

            var displayedVolume = originalVolume
            var scalarError: String?
            if currentSnapshot.canSetVolume, originalVolume > adjustedVolume + 0.005 {
                do {
                    try audioController.setVolume(adjustedVolume)
                    displayedVolume = adjustedVolume
                } catch {
                    // Muting already succeeded, so keep the successful safety
                    // action and report only the secondary scalar-write issue.
                    scalarError = "已静音，但未能同步降低音量：\(error.localizedDescription)"
                }
            }
            let event = ProtectionEvent(
                appName: appName,
                deviceName: currentSnapshot.deviceName,
                previousVolume: originalVolume,
                adjustedVolume: displayedVolume,
                ruleName: "耳机离开保护",
                kind: .headphoneExitMuted
            )
            record(event: event, settings: settings)
            return HeadphoneExitResult(
                displayedVolume: displayedVolume,
                errorMessage: scalarError
            )
        case let .reduce(targetVolume):
            return reduceAfterHeadphoneExit(
                currentSnapshot: currentSnapshot,
                settings: settings,
                limit: limit,
                appName: appName,
                originalVolume: originalVolume,
                targetVolume: targetVolume
            )
        case .unavailable:
            return HeadphoneExitResult(
                displayedVolume: currentSnapshot.volume,
                errorMessage: "当前输出设备不支持耳机离开保护"
            )
        }
    }

    private func reduceAfterHeadphoneExit(
        currentSnapshot: AudioDeviceSnapshot,
        settings: GuardSettings,
        limit: VolumeLimit,
        appName: String,
        originalVolume: Double,
        targetVolume: Double? = nil
    ) -> HeadphoneExitResult {
        let target = targetVolume ?? min(originalVolume, settings.headphoneExitVolume, limit.value)
        guard originalVolume > target + 0.005 else {
            return HeadphoneExitResult(displayedVolume: originalVolume, errorMessage: nil)
        }
        do {
            try audioController.setVolume(target)
            let event = ProtectionEvent(
                appName: appName,
                deviceName: currentSnapshot.deviceName,
                previousVolume: originalVolume,
                adjustedVolume: target,
                ruleName: "耳机离开保护",
                kind: .headphoneExitReduced
            )
            record(event: event, settings: settings)
            return HeadphoneExitResult(displayedVolume: target, errorMessage: nil)
        } catch {
            return HeadphoneExitResult(
                displayedVolume: currentSnapshot.volume,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func record(event: ProtectionEvent, settings: GuardSettings) {
        eventStore.append(event)
        onProtectionEvent?(event)
        sendNotificationIfNeeded(event: event, settings: settings)
    }

    private func scheduleEvaluation(trigger: ProtectionTrigger) {
        if pendingTrigger == nil
            || trigger.evaluationPriority > (pendingTrigger?.evaluationPriority ?? -1) {
            pendingTrigger = trigger
        }
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let trigger = self.pendingTrigger ?? .manualCheck
            self.pendingTrigger = nil
            self.evaluationScheduled = false
            self.evaluateNow(trigger: trigger)
        }
    }

    private func handleApplicationActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular else { return }
        lastExternalApplication = app
        scheduleEvaluation(trigger: .applicationChanged)
    }

    private func refreshForegroundApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           app.activationPolicy == .regular {
            lastExternalApplication = app
        }
    }

    private func configurePauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let until = pauseUntil else { return }
        let timer = Timer(timeInterval: max(0, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.resume()
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func sendNotificationIfNeeded(event: ProtectionEvent, settings: GuardSettings) {
        guard settings.notificationsEnabled,
              Date().timeIntervalSince(lastNotificationDate) >= 3 else { return }
        lastNotificationDate = Date()

        let content = UNMutableNotificationContent()
        switch event.kind {
        case .volumeReduced:
            content.title = "音量卫士已阻止意外高音量"
            content.body = String(
                format: "%@：%d%% → %d%%（%@）",
                event.appName,
                Int((event.previousVolume * 100).rounded()),
                Int((event.adjustedVolume * 100).rounded()),
                event.ruleName
            )
        case .headphoneExitMuted:
            content.title = "耳机已离开，输出已静音"
            content.body = "当前输出：\(event.deviceName)"
        case .headphoneExitReduced:
            content.title = "耳机已离开，音量已降低"
            content.body = String(
                format: "%@：%d%% → %d%%",
                event.deviceName,
                Int((event.previousVolume * 100).rounded()),
                Int((event.adjustedVolume * 100).rounded())
            )
        }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let request = UNNotificationRequest(
                identifier: event.id.uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
        center.getNotificationSettings { notificationSettings in
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { deliver() }
                }
            default:
                break
            }
        }
    }
}
