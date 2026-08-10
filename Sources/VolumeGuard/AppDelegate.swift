import AppKit
import VolumeGuardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: SettingsStore!
    private var eventStore: ProtectionEventStore!
    private var audioController: SystemAudioController!
    private var protectionController: ProtectionController!
    private var launchAtLoginManager: LaunchAtLoginManager!
    private var settingsWindowController: SettingsWindowController!
    private var statusMenuController: StatusMenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults: UserDefaults
        if let suiteName = ProcessInfo.processInfo.environment["VOLUME_GUARD_TEST_SUITE"],
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
            launchAtLoginManager: launchAtLoginManager
        )
        statusMenuController = StatusMenuController(
            settingsStore: settingsStore,
            eventStore: eventStore,
            protectionController: protectionController,
            settingsWindowController: settingsWindowController
        )

        protectionController.onStatusChange = { [weak self] status in
            self?.statusMenuController.updateStatus(status)
        }
        protectionController.start()

        // Used by local UI smoke tests; normal login launch stays silent.
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.settingsWindowController.showWindow(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        protectionController?.stop()
    }
}
