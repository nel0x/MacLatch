import ServiceManagement

/// "Start at Login" via `SMAppService` (macOS 13+). No helper, no LaunchAgent plist,
/// no extra permission; macOS shows its own "Login item added" notice and the user can
/// remove it any time in System Settings → General → Login Items.
///
/// Starting at login never arms anything: without the key the guard starts unarmed.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings.
        case requiresApproval
        /// Not running from an app bundle (e.g. `swift run`), so it cannot be registered.
        case unavailable
    }

    static var state: State {
        guard AppInstallation.isAppBundle else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
