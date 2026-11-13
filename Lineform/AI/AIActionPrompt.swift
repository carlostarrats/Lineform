import Foundation

/// The exact instructions sent for each AI action. The model is told nothing about the
/// document beyond the prose pieces themselves; Markdown structure never leaves the app.
enum AIActionPrompt {
    static let editSystem = "You edit prose for a writer. The user message is JSON with an action and a list of segments: consecutive pieces of one passage. Markdown formatting between segments was removed and will be restored by the app. Reply with JSON only, in the form {\"segments\": [...]}, with exactly the same number of strings in the same order. Never add Markdown, line breaks, quotes around the passage, or commentary. Keep the writer's language and voice."

    static let markSystem = "You review prose for a writer. The user message is JSON with an action and a numbered list of sentences (the first is 1). Reply with JSON only, in the form {\"sentences\": [numbers]}. Choose at most a third of them."

    /// The per-action line appended to the system text.
    static func instruction(for action: AIAction) -> String {
        switch action {
        case .trim: return "Remove needless words. Keep the meaning. Change as little as possible."
        case .cutInHalf: return "Make the passage about half as long. Keep the most important points."
        case .rewrite: return "Rewrite for clarity and flow. Keep the meaning and about the same length."
        case .proofread: return "Fix only spelling, typos, grammar slips and prose punctuation. Change nothing else."
        case .markWeakest: return "Choose the weakest sentences: vague, flat or unclear."
        case .markLong: return "Choose sentences too long to read comfortably."
        }
    }

    static func editPrompt(_ action: AIAction, segments: [String]) -> AIPrompt {
        AIPrompt(system: editSystem + "\n" + instruction(for: action),
                 user: json(["action": action.rawValue, "segments": segments]))
    }

    static func markPrompt(_ action: AIAction, sentences: [String]) -> AIPrompt {
        AIPrompt(system: markSystem + "\n" + instruction(for: action),
                 user: json(["action": action.rawValue, "sentences": sentences]))
    }

    private static func json(_ object: [String: Any]) -> String {
        // Strings and arrays of strings always serialize; the fallback is unreachable.
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
