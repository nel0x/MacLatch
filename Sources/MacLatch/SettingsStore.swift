import Foundation
import MacLatchCore

/// Persistent user preferences.
///
/// Never stores runtime guard state (armed / pending lock). Those are always
/// re-derived from the physically attached devices after a restart.
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let configuredKey = "configuredYubiKey"
        static let monitorMode = "monitorMode"
        static let lockDelaySeconds = "lockDelaySeconds"
        static let didOfferStartAtLogin = "didOfferStartAtLogin"
        static let suppressMoveToApplicationsPrompt = "suppressMoveToApplicationsPrompt"
        static let keepAwake = "keepAwake"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuredKey: ConfiguredYubiKey? {
        get {
            guard let data = defaults.data(forKey: Key.configuredKey) else { return nil }
            return try? JSONDecoder().decode(ConfiguredYubiKey.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.configuredKey)
            } else {
                defaults.removeObject(forKey: Key.configuredKey)
            }
        }
    }

    /// Defaults to `true`: a fresh install only logs what it would do until the user
    /// has validated the behavior with their hardware and turns real locking on.
    var monitorMode: Bool {
        get { defaults.object(forKey: Key.monitorMode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.monitorMode) }
    }

    static let lockDelayOptions = [0, 1, 3, 5, 10, 15]
    static let defaultLockDelaySeconds = 3

    /// Grace period after removal. Unknown or corrupt stored values fall back to the default.
    var lockDelaySeconds: Int {
        get {
            guard let stored = defaults.object(forKey: Key.lockDelaySeconds) as? Int,
                  Self.lockDelayOptions.contains(stored)
            else { return Self.defaultLockDelaySeconds }
            return stored
        }
        set {
            guard Self.lockDelayOptions.contains(newValue) else { return }
            defaults.set(newValue, forKey: Key.lockDelaySeconds)
        }
    }

    var lockDelay: Duration { .seconds(lockDelaySeconds) }

    /// The one-time "Start at Login?" prompt was shown. (The login item itself is owned by macOS.)
    var didOfferStartAtLogin: Bool {
        get { defaults.bool(forKey: Key.didOfferStartAtLogin) }
        set { defaults.set(newValue, forKey: Key.didOfferStartAtLogin) }
    }

    /// Prevent idle system sleep (like `caffeinate -i`). Off by default.
    var keepAwake: Bool {
        get { defaults.bool(forKey: Key.keepAwake) }
        set { defaults.set(newValue, forKey: Key.keepAwake) }
    }

    var suppressMoveToApplicationsPrompt: Bool {
        get { defaults.bool(forKey: Key.suppressMoveToApplicationsPrompt) }
        set { defaults.set(newValue, forKey: Key.suppressMoveToApplicationsPrompt) }
    }
}
