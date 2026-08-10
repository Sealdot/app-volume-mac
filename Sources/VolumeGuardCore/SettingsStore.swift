import Foundation

public final class SettingsStore {
    public static let didChangeNotification = Notification.Name("VolumeGuard.SettingsDidChange")

    private let defaults: UserDefaults
    private let storageKey: String
    public private(set) var settings: GuardSettings

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "VolumeGuard.settings"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.settings = Self.load(defaults: defaults, key: storageKey)
    }

    public func update(_ mutation: (inout GuardSettings) -> Void) {
        var next = settings
        mutation(&next)
        settings = next.normalized()
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func reset() {
        settings = GuardSettings()
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults, key: String) -> GuardSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(GuardSettings.self, from: data) else {
            return GuardSettings()
        }
        return decoded.normalized()
    }
}

public final class ProtectionEventStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumCount: Int
    public private(set) var events: [ProtectionEvent]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "VolumeGuard.protectionEvents",
        maximumCount: Int = 200
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumCount = max(1, maximumCount)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ProtectionEvent].self, from: data) {
            self.events = Array(decoded.prefix(self.maximumCount))
        } else {
            self.events = []
        }
    }

    public func append(_ event: ProtectionEvent) {
        events.insert(event, at: 0)
        if events.count > maximumCount {
            events.removeLast(events.count - maximumCount)
        }
        persist()
    }

    public func removeAll() {
        events.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
