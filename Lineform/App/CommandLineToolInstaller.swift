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
        return "ln -sf \"\(helper)\" \"\(destination)\""
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
            // removeItem uses lstat semantics, so this also clears a dangling symlink
            // (fileExists(atPath:) follows links and would miss it).
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: helper)
            showSuccess(destination: destination.path)
        } catch {
            showManualFallback(destination: destination.path,
                               reason: "Couldn’t create the link at \(destination.path).")
        }
    }

    @MainActor
    private static func showSuccess(destination: String) {
        // The symlink is silent otherwise; close the loop so the user knows it worked and how to
        // use it. It's a Terminal command, and a shell that was already open won't have the new
        // PATH entry — hence "open a new Terminal window". Use the destination's actual basename
        // as the command name: the save panel pre-fills "lineform" but lets the user rename it.
        let command = (destination as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Command line tool installed"
        alert.informativeText = """
        \(command) was linked to \(destination).

        Open a new Terminal window, then run:

        \(command) yourfile.md

        Or pipe input into it:

        some-command | \(command) -
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
