import Foundation

enum LaunchAtLoginError: LocalizedError {
    case notRunningFromAppBundle
    case missingExecutable

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "请先将音量卫士构建为 .app，再开启登录时启动"
        case .missingExecutable:
            return "无法找到 App 可执行文件"
        }
    }
}

/// A deliberately small, dependency-free login item implementation for the
/// macOS 10.15 deployment target. It writes one user-owned LaunchAgent plist and
/// never asks for administrator privileges.
final class LaunchAtLoginManager {
    private let fileManager: FileManager
    private let label = "com.volumeguard.app"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writeLaunchAgent()
        } else if isEnabled {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    func refreshPathIfEnabled() {
        guard isEnabled else { return }
        try? writeLaunchAgent()
    }

    private func writeLaunchAgent() throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw LaunchAtLoginError.notRunningFromAppBundle
        }
        guard let executableURL = Bundle.main.executableURL else {
            throw LaunchAtLoginError.missingExecutable
        }

        let directory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let payload: [String: Any] = [
            "Label": label,
            // A login launch stays quietly in the menu bar. Direct launches
            // intentionally omit this flag and open Settings as feedback.
            "ProgramArguments": [executableURL.path, "--login-item"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }
}
