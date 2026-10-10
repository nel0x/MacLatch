import AppKit

/// One-time prompts after launch, the way downloaded apps usually do it:
/// first offer to move into /Applications, then (only from there) offer "Start at Login".
@MainActor
struct Onboarding {
    let settings: SettingsStore
    let record: (String) -> Void

    func run() {
        guard AppInstallation.isAppBundle else { return }

        if !AppInstallation.isInApplicationsFolder {
            if !settings.suppressMoveToApplicationsPrompt { offerMoveToApplications() }
            return // a login item is only reliable from /Applications
        }

        if !settings.didOfferStartAtLogin, LoginItem.state == .disabled {
            offerStartAtLogin()
        }
    }

    func offerMoveToApplications() {
        let alert = NSAlert()
        alert.messageText = "Move MacLatch to the Applications folder?"
        alert.informativeText = "MacLatch should run from the Applications folder so it can start at login reliably."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.suppressMoveToApplicationsPrompt = true }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try AppInstallation.moveToApplicationsAndRelaunch()
            record("Moved to /Applications, relaunching")
        } catch {
            showError(error)
        }
    }

    func offerStartAtLogin() {
        settings.didOfferStartAtLogin = true

        let alert = NSAlert()
        alert.messageText = "Start MacLatch automatically at login?"
        alert.informativeText = "You can change this any time in the MacLatch menu or in System Settings → General → Login Items. Without your YubiKey, MacLatch always starts unarmed."
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setStartAtLogin(true)
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            record("Start at Login \(enabled ? "enabled" : "disabled")")
            if LoginItem.state == .requiresApproval { LoginItem.openSystemSettings() }
        } catch {
            record("Start at Login could not be changed")
            showError(error, suggestion: "You can add MacLatch manually in System Settings → General → Login Items.")
            LoginItem.openSystemSettings()
        }
    }

    private func showError(_ error: any Error, suggestion: String? = nil) {
        let alert = NSAlert(error: error)
        if let suggestion { alert.informativeText = suggestion }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
