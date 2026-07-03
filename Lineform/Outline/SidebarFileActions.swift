import AppKit
import SwiftUI

/// File-system side of the sidebar's Rename/Delete actions, behind a protocol so unit
/// tests can observe calls without touching the real Trash. Delete is trash-only by
/// design — the app never permanently removes a user's file.
protocol SidebarFileManaging {
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL) throws
}

extension FileManager: SidebarFileManaging {
    func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
    }
}

enum SidebarFileRenaming {
    /// What the rename dialog's text field shows: files without their extension
    /// (the extension is preserved automatically), folders as their whole name.
    static func displayName(for url: URL, isDirectory: Bool) -> String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The rename target for a user-entered name, or nil when the name is empty,
    /// unchanged, or contains a path separator ("/" or the legacy ":").
    static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL? {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            return nil
        }

        let ext = isDirectory ? "" : url.pathExtension
        let newName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        guard newName != url.lastPathComponent else {
            return nil
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: isDirectory)
    }
}

/// Copy + the Show-in-Finder action for the sidebar's file dialogs. The dialogs
/// themselves are custom SwiftUI (see below) — NOT `NSAlert`, which forces the app
/// icon and standard-alert chrome and cannot match the clean Muse-style modal.
enum SidebarFileActionPresenter {
    static let renameFileTitle = "Rename File"
    static let renameFolderTitle = "Rename Folder"
    static let renameFileMessage = "Renames the file. Its contents are kept."
    static let renameFolderMessage = "Renames the folder. Its files are kept."
    static let renameButtonTitle = "Rename"
    static let cancelButtonTitle = "Cancel"
    static let deleteButtonTitle = "Delete"
    static let deleteMessage = "It will be moved to the Trash."

    static func deleteTitle(for url: URL) -> String {
        "Delete “\(url.lastPathComponent)”?"
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Plain, deliberately UNcoordinated file operations.
///
/// No `NSFileCoordinator` here: coordinating a write on the main thread against a file the
/// same process's `NSDocument` presents (renaming/deleting the open document — the primary
/// use) can deadlock, and letting presenters observe the move makes `NSDocument` follow a
/// trashed file into the Trash, where the next autosave would resurrect it. In-app windows
/// are retargeted explicitly instead via `LineformAppNotification.sidebarItemRenamed` /
/// `sidebarFileDeleted`, and sidebars refresh via `refreshSidebarFiles`.
struct SidebarFileOperations {
    var fileManager: SidebarFileManaging = FileManager.default

    /// Errors (destination exists, no permission) surface as the system-localized
    /// `moveItem` error — no pre-flight, so case-only renames work on case-insensitive
    /// volumes ("notes.md" → "Notes.md", which a naive exists-check would reject).
    func rename(_ url: URL, to destination: URL) throws {
        try fileManager.moveItem(at: url, to: destination)
    }

    /// Never `removeItem` — always the Trash, always recoverable.
    func trash(_ url: URL) throws {
        try fileManager.trashItem(at: url)
    }
}

// MARK: - Muse-style dialogs

/// A pending rename, used as the presenting view's sheet/overlay state.
struct SidebarRenameRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
}

/// Shared chrome for the sidebar's file dialogs: a dimmed backdrop over the whole window
/// and a centered rounded card — the Muse look. Deliberately NOT an `NSAlert` (no app
/// icon, full control of the button row). Theme-aware via semantic colors.
private struct SidebarDialogChrome<Content: View>: View {
    var onCancel: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.5 : 0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 13) {
                content()
            }
            .padding(20)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        }
    }
}

/// Muse-style dialog buttons: filled pills, each half-width. Primary = accent, secondary
/// = neutral fill, destructive = red with WHITE text (the old `NSAlert` destructive style
/// rendered red-on-red and was unreadable).
private struct SidebarDialogButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundStyle(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(Rectangle())
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .destructive: return .white
        case .secondary: return .primary
        }
    }

    private var fillColor: Color {
        switch kind {
        case .primary: return .accentColor
        case .destructive: return Color(nsColor: .systemRed)
        case .secondary: return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09)
        }
    }
}

/// A single-line text field that grabs focus and selects all its text on appear — SwiftUI's
/// `TextField` can't pre-select, and Muse shows the name highlighted and ready to replace.
private struct SidebarRenameTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SidebarRenameTextField

        init(_ parent: SidebarRenameTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Rename dialog matching the Muse reference: title, one-line explanation, a pre-selected
/// name field, and Cancel / Rename buttons (Rename is the accent default action).
struct SidebarRenameDialog: View {
    let url: URL
    let isDirectory: Bool
    var onCommit: (URL) -> Void
    var onCancel: () -> Void

    @State private var name: String

    init(url: URL, isDirectory: Bool, onCommit: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.isDirectory = isDirectory
        self.onCommit = onCommit
        self.onCancel = onCancel
        _name = State(initialValue: SidebarFileRenaming.displayName(for: url, isDirectory: isDirectory))
    }

    var body: some View {
        SidebarDialogChrome(onCancel: onCancel) {
            Text(isDirectory ? SidebarFileActionPresenter.renameFolderTitle : SidebarFileActionPresenter.renameFileTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text(isDirectory ? SidebarFileActionPresenter.renameFolderMessage : SidebarFileActionPresenter.renameFileMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SidebarRenameTextField(text: $name, onCommit: commit, onCancel: onCancel)
                .frame(height: 22)
                .padding(.vertical, 2)

            HStack(spacing: 10) {
                Button(SidebarFileActionPresenter.cancelButtonTitle, action: onCancel)
                    .buttonStyle(SidebarDialogButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(SidebarFileActionPresenter.renameButtonTitle, action: commit)
                    .buttonStyle(SidebarDialogButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private func commit() {
        if let destination = SidebarFileRenaming.validatedDestination(for: url, isDirectory: isDirectory, newDisplayName: name) {
            onCommit(destination)
        } else {
            // Empty / unchanged / invalid name is a no-op dismissal.
            onCancel()
        }
    }
}

/// Delete confirmation matching the Muse look: title, "moved to the Trash" line, and
/// Cancel / Delete. Delete is a readable red pill (white text) and is NOT the keyboard
/// default — deleting is deliberate, so it takes a click; Escape cancels.
struct SidebarDeleteDialog: View {
    let url: URL
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        SidebarDialogChrome(onCancel: onCancel) {
            Text(SidebarFileActionPresenter.deleteTitle(for: url))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(SidebarFileActionPresenter.deleteMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(SidebarFileActionPresenter.cancelButtonTitle, action: onCancel)
                    .buttonStyle(SidebarDialogButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(SidebarFileActionPresenter.deleteButtonTitle, action: onConfirm)
                    .buttonStyle(SidebarDialogButtonStyle(kind: .destructive))
            }
            .padding(.top, 2)
        }
    }
}
