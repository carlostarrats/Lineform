import Foundation

/// What the right-hand pane of Connect Your AI shows for one provider.
enum ConnectAIPaneState: Equatable {
    /// "Connected" plus Disconnect.
    case connected
    /// The key field (or Other's address fields) and the consent button. `reconnect` is set
    /// when the store says this provider is connected but its key is gone from the Keychain:
    /// the writer must paste it again, and the pane says why.
    case needsKey(reconnect: Bool)
}

/// Copy and display decisions for Connect Your AI, kept out of the view so they can be
/// tested without a window. Every string is chrome and localizes; brand and company names
/// do not.
enum ConnectAIPresentation {
    /// Also the name `AIClientError` messages point writers to ("Check it in Connect Your AI"),
    /// in every language. `ConnectAIPresentationTests` asserts the two agree.
    static var title: String { title(bundle: .main) }
    static func title(bundle: Bundle) -> String {
        String(localized: "Connect Your AI", bundle: bundle)
    }

    static var createKeyTitle: String { String(localized: "Create an API key") }
    static var keyLabel: String { String(localized: "API key") }
    static var addressLabel: String { String(localized: "Address") }
    static var optionalKeyLabel: String { String(localized: "API key (optional)") }
    static var optionalModelLabel: String { String(localized: "Model (optional)") }
    static var connectedText: String { String(localized: "Connected") }
    static var disconnectTitle: String { String(localized: "Disconnect") }
    static var reconnectNote: String {
        String(localized: "Lineform can't find this key in your Keychain. Paste it again to reconnect.")
    }

    static var privacyNote: String { privacyNote(bundle: .main) }
    static func privacyNote(bundle: Bundle) -> String {
        String(localized: "Lineform sends only the text you act on, only when you choose an AI action, directly to the provider you connected, under your account and that provider's terms. Lineform's developer receives nothing.", bundle: bundle)
    }

    static func billingNote(for provider: AIProvider, bundle: Bundle = .main) -> String {
        switch provider {
        case .claude:
            return String(localized: "A Claude Pro or Max subscription doesn't cover this. API keys are billed per use by Anthropic.", bundle: bundle)
        case .chatGPT:
            return String(localized: "A ChatGPT Plus or Pro subscription doesn't cover this. API keys are billed per use by OpenAI.", bundle: bundle)
        case .google:
            return String(localized: "A Gemini subscription doesn't cover this. API keys are billed per use by Google.", bundle: bundle)
        case .other:
            return String(localized: "Use a model on this Mac — Ollama, LM Studio, llama.cpp — or any OpenAI-compatible server.", bundle: bundle)
        }
    }

    /// The consent step: the button names what is sent and to whom.
    static func connectButtonTitle(for provider: AIProvider, otherHost: String?) -> String {
        let host = otherHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let recipient = provider.companyName ?? (host.isEmpty ? nil : host) else {
            return String(localized: "Connect — Lineform will send the text you choose to that address")
        }
        return String(localized: "Connect — Lineform will send the text you choose to \(recipient)")
    }

    /// The host of what the writer has typed into Other's Address field, for the consent
    /// button. Nil until it parses as an address with a host.
    static func host(fromAddress address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
        return host
    }

    static func paneState(for provider: AIProvider, connectedProvider: AIProvider?,
                          keyMissing: Bool) -> ConnectAIPaneState {
        guard provider == connectedProvider else { return .needsKey(reconnect: false) }
        return keyMissing ? .needsKey(reconnect: true) : .connected
    }

    /// The list row's checkmark. A provider whose key went missing is not shown as connected.
    static func showsConnectedMark(for provider: AIProvider, connectedProvider: AIProvider?,
                                   keyMissing: Bool) -> Bool {
        paneState(for: provider, connectedProvider: connectedProvider, keyMissing: keyMissing) == .connected
    }
}
