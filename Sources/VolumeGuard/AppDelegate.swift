import AppKit
import VolumeGuardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showSettingsNotification = Notification.Name("com.volumeguard.app.showSettings")

    private var settingsStore: SettingsStore!
    private var eventStore: ProtectionEventStore!
    private var audioController: SystemAudioController!
    private var protectionController: ProtectionController!
    private var launchAtLoginManager: LaunchAtLoginManager!
    private var settingsWindowController: SettingsWindowController!
    private var statusMenuController: StatusMenuController!
    private var showSettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstanceIfNeeded() {
            return
        }

        let defaults: UserDefaults
        let suiteArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--test-suite=") })
        let suiteFromArgument = suiteArgument.flatMap { argument -> String? in
            guard let separator = argument.firstIndex(of: "=") else { return nil }
            return String(argument[argument.index(after: separator)...])
        }
        if let suiteName = ProcessInfo.processInfo.environment["VOLUME_GUARD_TEST_SUITE"] ?? suiteFromArgument,
           let isolatedDefaults = UserDefaults(suiteName: suiteName) {
            defaults = isolatedDefaults
        } else {
            defaults = .standard
        }
        settingsStore = SettingsStore(defaults: defaults)
        if ProcessInfo.processInfo.environment["VOLUME_GUARD_DISABLE_PROTECTION"] == "1" {
            settingsStore.update {
                $0.isProtectionEnabled = false
                $0.notificationsEnabled = false
            }
        }
        if CommandLine.arguments.contains("--ui-fixture") {
            settingsStore.update {
                $0.defaultMaximumVolume = 0.20
                $0.appRules = [
                    AppVolumeRule(
                        bundleIdentifier: "us.zoom.xos",
                        appName: "Zoom",
                        maximumVolume: 1.0
                    ),
                    AppVolumeRule(
                        bundleIdentifier: "com.apple.Music",
                        appName: "音乐",
                        maximumVolume: 0.20
                    )
                ]
            }
        }
        eventStore = ProtectionEventStore(defaults: defaults, maximumCount: 20)
        audioController = SystemAudioController()
        launchAtLoginManager = LaunchAtLoginManager()
        launchAtLoginManager.refreshPathIfEnabled()

        // The plist on disk is the source of truth if the user removed the login
        // item outside the app.
        if settingsStore.settings.launchAtLogin != launchAtLoginManager.isEnabled {
            settingsStore.update { $0.launchAtLogin = launchAtLoginManager.isEnabled }
        }

        protectionController = ProtectionController(
            settingsStore: settingsStore,
            eventStore: eventStore,
            audioController: audioController
        )
        settingsWindowController = SettingsWindowController(
            settingsStore: settingsStore,
            launchAtLoginManager: launchAtLoginManager,
            protectionController: protectionController
        )
        statusMenuController = StatusMenuController(
            settingsStore: settingsStore,
            eventStore: eventStore,
            protectionController: protectionController,
            settingsWindowController: settingsWindowController
        )

        showSettingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showSettingsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showSettings()
        }

        protectionController.onStatusChange = { [weak self] status in
            self?.statusMenuController.updateStatus(status)
        }
        protectionController.start()

        // A direct Finder/Codex launch needs visible feedback. Login launches
        // stay silent and test launches explicitly control their own windows.
        if shouldShowSettingsAtLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
            }
        }

        if let snapshotArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-settings=") }),
           let separator = snapshotArgument.firstIndex(of: "=") {
            let path = String(snapshotArgument[snapshotArgument.index(after: separator)...])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if CommandLine.arguments.contains("--snapshot-pane=rules") {
                    self.settingsWindowController.showRules()
                } else {
                    self.settingsWindowController.showWindow(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let didWrite = self.settingsWindowController.writeSnapshot(to: URL(fileURLWithPath: path))
                    let result = didWrite ? "设置截图已写入：\(path)\n" : "设置截图写入失败：\(path)\n"
                    FileHandle.standardError.write(Data(result.utf8))
                    self.settingsWindowController.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = showSettingsObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        protectionController?.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    private var isAutomationLaunch: Bool {
        ProcessInfo.processInfo.environment["VOLUME_GUARD_TEST_SUITE"] != nil
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--test-suite=") })
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-settings=") })
    }

    private var shouldShowSettingsAtLaunch: Bool {
        if CommandLine.arguments.contains("--show-settings") {
            return true
        }
        return !isAutomationLaunch
            && !CommandLine.arguments.contains("--login-item")
            && !CommandLine.arguments.contains("--background")
    }

    private func handOffToRunningInstanceIfNeeded() -> Bool {
        guard !isAutomationLaunch,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID && !$0.isTerminated }) else {
            return false
        }

        DistributedNotificationCenter.default().post(
            name: Self.showSettingsNotification,
            object: nil,
            userInfo: nil
        )
        existing.activate(options: [.activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return true
    }

    private func showSettings() {
        guard settingsWindowController != nil else { return }
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
