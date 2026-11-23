import Combine
import CoreGraphics
import Foundation

/// The AI group of the editor's context menu, and of every surface that offers the same actions
/// (the Mac's selection toolbar, the iPhone's selection row). Moved from the Mac's
/// `LineformTextContextMenuPresentation`, which forwards to it under the same names.
public enum AIMenuPresentation {
    /// The AI group's submenus. Conditional (connected, a selection with prose).
    public static var aiRewriteMenuTitle: String { String(localized: "Rewrite", bundle: .module) }
    /// "Find ▸ Weakest Sentences / Long Sentences" (2026-11-14; was "Mark").
    public static var aiMarkMenuTitle: String { String(localized: "Find", bundle: .module) }

    /// One row of the AI group: an action, or a submenu of actions.
    public enum AIMenuEntry: Equatable {
        case action(AIAction)
        /// A submenu of action groups, a separator between groups.
        case submenu(String, [[AIAction]])
    }

    /// The AI group for a selection. A single word gets "Another Word" in place of the Rewrite
    /// submenu (Trim / Cut in half / Rewrite make no sense for one word); Proofread is always
    /// there; Mark only when the selection touches at least two sentences (marking "the weakest"
    /// of one sentence is meaningless). `sentenceCount` is a closure so a single word never pays
    /// for the sentence split. The whole document (Ask AI… with nothing selected) is offered the
    /// same way, with the document's text as `selectedText`.
    public static func aiMenuEntries(selectedText: String, sentenceCount: () -> Int) -> [AIMenuEntry] {
        guard !isSingleWord(selectedText) else {
            return [.action(.anotherWord), .action(.proofread)]
        }
        var entries: [AIMenuEntry] = [.submenu(aiRewriteMenuTitle, AIAction.rewriteMenuGroups), .action(.proofread)]
        if sentenceCount() >= 2 {
            entries.append(.submenu(aiMarkMenuTitle, [[.markWeakest, .markLong]]))
        }
        return entries
    }

    /// One word: once trimmed, no whitespace inside and at least one letter ("don't", "e-mail"
    /// and "Café," count; "42" and "—" don't).
    public static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return false
        }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}

/// The selection toolbar's pure decisions (2026-11-17), shared by the Mac's floating toolbar and
/// comment card and the iPhone's selection row and comment field: one-click formatting, plus —
/// only while an AI is connected — a comment to that AI.
///
/// The comment sends the writer's note with an optional action (`AIAction`); `.custom` means
/// "only the note". The result is the ordinary AI review: nothing changes until accepted.
public enum SelectionToolbarPresentation {
    public static func aiName(for provider: AIProvider, bundle: Bundle = .lineformCore) -> String {
        provider == .other ? String(localized: "Your AI", bundle: bundle) : provider.displayName
    }

    public static func commentTitle(aiName: String, bundle: Bundle = .lineformCore) -> String {
        String(localized: "Ask \(aiName)", bundle: bundle)
    }

    public static var notePlaceholder: String { String(localized: "What should change?", bundle: .module) }
    public static var actionLabel: String { String(localized: "Action:", bundle: .module) }
    public static var sendTitle: String { String(localized: "Send", bundle: .module) }
    public static var sendHint: String { String(localized: "Return to send · Esc", bundle: .module) }
    public static var headingTitle: String { String(localized: "Heading", bundle: .module) }
    public static var listTitle: String { String(localized: "List", bundle: .module) }
    public static var dragHint: String { String(localized: "Drag to move", bundle: .module) }

    /// The comment card's action menu: Custom, then the same actions — with the same rules — as
    /// the context menu's AI group (one word: Another Word; Find only for two or more sentences).
    public static func actionGroups(selectedText: String, sentenceCount: () -> Int) -> [[AIAction]] {
        var groups: [[AIAction]] = [[.custom]]
        for entry in AIMenuPresentation.aiMenuEntries(selectedText: selectedText, sentenceCount: sentenceCount) {
            switch entry {
            case .action(let action): groups.append([action])
            case .submenu(_, let submenuGroups): groups.append(contentsOf: submenuGroups)
            }
        }
        // Another Word and Proofread arrive as two one-item groups; keep them together.
        var merged: [[AIAction]] = []
        for group in groups {
            if group.count == 1, let last = merged.last, last.count == 1, last != [.custom] {
                merged[merged.count - 1].append(contentsOf: group)
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    /// The action's name in the comment card. The Find actions live in a "Find ▸" submenu on the
    /// context menu; out here, flat, they say what they do.
    public static func menuTitle(for action: AIAction, bundle: Bundle = .lineformCore) -> String {
        switch action {
        case .markWeakest: return String(localized: "Find Weakest Sentences", bundle: bundle)
        case .markLong: return String(localized: "Find Long Sentences", bundle: bundle)
        case .custom: return String(localized: "Custom", bundle: bundle)
        default: return action.title
        }
    }

    /// Custom needs a note; any other action may be sent with or without one.
    public static func canSend(action: AIAction, note: String) -> Bool {
        action != .custom || AIActionPrompt.trimmedNote(note) != nil
    }

    /// Where the bar goes, in the text view's (flipped) coordinates: centred over the selection's
    /// first line, above it when there is room inside the visible rect, otherwise below the
    /// selection's last line; always kept inside the visible rect.
    public static func origin(barSize: CGSize, firstLine: CGRect, lastLine: CGRect, visible: CGRect,
                              gap: CGFloat = 8, margin: CGFloat = 8) -> CGPoint {
        var x = firstLine.midX - barSize.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - barSize.width - margin)
        var y = firstLine.minY - gap - barSize.height
        if y < visible.minY + margin {
            y = lastLine.maxY + gap
        }
        y = min(max(y, visible.minY + margin), visible.maxY - barSize.height - margin)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

/// The state behind the selection toolbar and its comment card. The views (AppKit/SwiftUI on the
/// Mac) stay in each app.
@MainActor
public final class SelectionToolbarModel: ObservableObject {
    public enum Mode { case toolbar, comment }

    @Published public var mode: Mode = .toolbar
    @Published public var showsFormatting = true
    /// The connected AI's name; nil hides the comment button (no AI UI without a connection).
    @Published public var aiName: String?
    @Published public var usesDarkChrome = false
    @Published public var note = ""
    @Published public var action: AIAction = .custom
    /// Bumped to move keyboard focus into the note field.
    @Published public var focusToken = 0

    /// Button frames in the hosting view's coordinates, for anchoring their menus.
    public var headingButtonFrame: CGRect = .zero
    public var listButtonFrame: CGRect = .zero
    public var actionButtonFrame: CGRect = .zero

    public var onCommand: (Selector) -> Void = { _ in }
    public var onMenu: (SelectionToolbarMenu) -> Void = { _ in }
    public var onOpenComment: () -> Void = {}
    public var onSend: () -> Void = {}
    public var onClose: () -> Void = {}
    /// The card is being dragged (`ended` false) or was released (`true`). `translation`: how far
    /// the pointer has moved since the press — only its first value is used, to recover where the
    /// press was (the drag is recognised a few points in).
    public var onDrag: (_ translation: CGSize, _ ended: Bool) -> Void = { _, _ in }

    public init() {}

    public var canSend: Bool { SelectionToolbarPresentation.canSend(action: action, note: note) }
}

public enum SelectionToolbarMenu { case heading, list, action }
