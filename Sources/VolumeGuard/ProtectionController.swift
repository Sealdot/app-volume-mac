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
    var lastError: String?
}

final class ProtectionController {
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
    private var lastNotificationDate = Date.distantPast

    private(set) var status: GuardRuntimeStatus

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
            self?.scheduleEvaluation()
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

        audioController.startMonitoring { [weak self] in
            self?.scheduleEvaluation()
        }
        evaluateNow()
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
        evaluateNow()
    }

    func resume() {
        isPaused = false
        pauseUntil = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        evaluateNow()
    }

    func evaluateNow() {
        evaluationScheduled = false
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
        let limit = VolumePolicy.effectiveLimit(
            settings: settings,
            foregroundBundleIdentifier: bundleID
        )
        let snapshot = audioController.snapshot()

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
        if let volume = snapshot.volume,
           snapshot.canSetVolume,
           let decision = VolumePolicy.clampDecision(
               currentVolume: volume,
               settings: settings,
               foregroundBundleIdentifier: bundleID,
               isPaused: isPaused
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
                eventStore.append(event)
                onProtectionEvent?(event)
                sendNotificationIfNeeded(event: event, settings: settings)
            } catch {
                lastError = error.localizedDescription
                nextState = .unsupported
            }
        }

        let refreshedSnapshot = audioController.snapshot()
        status = GuardRuntimeStatus(
            state: nextState,
            currentVolume: refreshedSnapshot.volume,
            effectiveLimit: limit,
            deviceName: refreshedSnapshot.deviceName,
            foregroundAppName: appName,
            foregroundBundleIdentifier: bundleID,
            lastError: lastError
        )
        onStatusChange?(status)
    }

    private func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.evaluateNow()
        }
    }

    private func handleApplicationActivation(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = app
        }
        scheduleEvaluation()
    }

    private func refreshForegroundApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
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
        content.title = "音量卫士已阻止意外高音量"
        content.body = String(
            format: "%@：%d%% → %d%%（%@）",
            event.appName,
            Int((event.previousVolume * 100).rounded()),
            Int((event.adjustedVolume * 100).rounded()),
            event.ruleName
        )
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
