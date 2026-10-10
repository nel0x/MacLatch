import AppKit
import os

/// Where the app runs from, and moving it to /Applications.
@MainActor
enum AppInstallation {
    static let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private static let log = Logger(subsystem: "io.github.nel0x.maclatch", category: "install")

    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// True if running from /Applications or ~/Applications.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return path.hasPrefix(applicationsURL.path + "/") || path.hasPrefix(userApplications + "/")
    }

    enum MoveError: LocalizedError {
        case notAnAppBundle
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnAppBundle: "MacLatch is not running from an app bundle."
            case .copyFailed(let reason): "Could not copy MacLatch to /Applications: \(reason)"
            }
        }
    }

    /// Copies the running bundle to /Applications (replacing an older copy, which goes to the
    /// Trash), relaunches from there and quits this instance. The original is moved to the Trash
    /// if possible (not possible e.g. for a read-only translocated copy).
    static func moveToApplicationsAndRelaunch() throws {
        guard isAppBundle else { throw MoveError.notAnAppBundle }
        let source = Bundle.main.bundleURL
        let destination = applicationsURL.appendingPathComponent(source.lastPathComponent)
        let fileManager = FileManager.default

        terminateOtherInstances()

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            log.error("move to Applications failed: \(error.localizedDescription, privacy: .public)")
            throw MoveError.copyFailed(error.localizedDescription)
        }
        log.notice("copied to \(destination.path, privacy: .public)")

        do {
            try fileManager.trashItem(at: source, resultingItemURL: nil)
        } catch {
            log.info("original left in place: \(error.localizedDescription, privacy: .public)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true // same bundle ID is still running (us)
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Self.log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
                    return // keep running here rather than leaving the user without the app
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Asks other running copies (e.g. an older one started at login) to quit, so only one
    /// instance monitors the key afterwards.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != me {
            app.terminate()
        }
    }
}
