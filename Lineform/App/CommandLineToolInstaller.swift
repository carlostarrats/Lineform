import AppKit

/// Installs the bundled `lineform` helper by symlinking it to a user-chosen location
/// (default `/usr/local/bin`). Sandbox-friendly: the NSSavePanel grants write access to the
/// chosen path; a copyable manual `ln -s` fallback is shown if the link can't be created.
///
/// (Piped-file housekeeping lives in the unsandboxed helper, not here: the sandboxed app's
/// `homeDirectoryForCurrentUser` is its container, so it cannot enumerate the helper's real
/// `~/Library/Application Support/Lineform/Piped` directory.)
enum CommandLineToolInstaller {
    static let bundledHelperSubpath = "Contents/Helpers/lineform"
    static let defaultInstallDirectory = "/usr/local/bin"

    /// The bundled helper, if present (absent in plain Debug builds — it ships in packaged releases).
    static var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(bundledHelperSubpath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func manualCommand(destination: String) -> String {
        let helper = bundledHelperURL?.path ?? "/Applications/Lineform.app/\(bundledHelperSubpath)"
        return "ln -s \"\(helper)\" \"\(destination)\""
    }

    @MainActor
    static func presentInstaller() {
        guard let helper = bundledHelperURL else {
            showManualFallback(destination: defaultInstallDirectory + "/lineform",
                               reason: "The command line tool isn’t available in this build.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Install Command Line Tool"
        panel.message = "Choose where to install the lineform command (default: \(defaultInstallDirectory))."
        panel.nameFieldStringValue = "lineform"
        panel.directoryURL = URL(fileURLWithPath: defaultInstallDirectory, isDirectory: true)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: helper)
        } catch {
            showManualFallback(destination: destination.path,
                               reason: "Couldn’t create the link at \(destination.path).")
        }
    }

    @MainActor
    private static func showManualFallback(destination: String, reason: String) {
        let needsSudo = destination.hasPrefix("/usr/") || destination.hasPrefix("/opt/")
        let command = (needsSudo ? "sudo " : "") + manualCommand(destination: destination)
        let alert = NSAlert()
        alert.messageText = "Install manually"
        alert.informativeText = "\(reason)\n\nRun this in Terminal:\n\n\(command)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
