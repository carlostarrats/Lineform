import Foundation

/// The exact instructions sent for each AI action. The model is told nothing about the
/// document beyond the prose pieces themselves; Markdown structure never leaves the app.
enum AIActionPrompt {
    static let editSystem = "You edit prose for a writer. The user message is JSON with an action and a list of segments: consecutive pieces of one passage. Markdown formatting between segments was removed and will be restored by the app. Reply with JSON only, in the form {\"segments\": [...]}, with exactly the same number of strings in the same order. Never add Markdown, line breaks, quotes around the passage, or commentary. Keep the writer's language and voice."

    static let markSystem = "You review prose for a writer. The user message is JSON with an action and a numbered list of sentences (the first is 1). Reply with JSON only, in the form {\"sentences\": [numbers]}. Choose at most a third of them."

    /// The per-action line appended to the system text.
    static func instruction(for action: AIAction) -> String {
        let modelInstruction: String
        switch action {
        case .trim: modelInstruction = "Remove needless words. Keep the meaning. Change as little as possible otherwise, but always remove at least some words: never return the passage unchanged."
        case .cutInHalf: modelInstruction = "Make the passage about half as long. Keep the most important points. Never return the passage unchanged."
        case .rewrite: modelInstruction = "Rewrite for clarity and flow. Keep the meaning and about the same length. Always change the wording: never return the passage unchanged."
        case .proofread: modelInstruction = "Fix only spelling, typos, grammar slips and prose punctuation. Change nothing else."
        case .anotherWord: modelInstruction = "The passage is a single word. Return one different word, or a very short phrase, that could replace it: same meaning, same part of speech, matching its capitalization. Never return the same word."
        case .markWeakest: modelInstruction = "Choose the weakest sentences: vague, flat or unclear."
        case .markLong: modelInstruction = "Choose sentences too long to read comfortably."
        }
        return modelInstruction
    }

    /// Try Again's extra line, followed by the discarded suggestion as `{"segments": [...]}`.
    static let differentResultInstruction = "Give a different result than: "

    /// `avoiding`: the segments of the suggestion the writer just discarded with Try Again (same
    /// count and order as `segments`); the model is asked for a different result.
    static func editPrompt(_ action: AIAction, segments: [String], avoiding: [String]? = nil) -> AIPrompt {
        var system = editSystem + "\n" + instruction(for: action)
        if let avoiding {
            system += "\n" + differentResultInstruction + json(["segments": avoiding])
        }
        return AIPrompt(system: system, user: json(["action": action.rawValue, "segments": segments]))
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
