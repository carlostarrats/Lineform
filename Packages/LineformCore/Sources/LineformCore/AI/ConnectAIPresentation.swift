import Foundation

/// What the right-hand pane of Connect Your AI shows for one provider.
public enum ConnectAIPaneState: Equatable {
    /// "Connected" plus Disconnect.
    case connected
    /// The key field (or Other's address fields) and the consent button. `reconnect` is set
    /// when the store says this provider is connected but its key is gone from the Keychain:
    /// the writer must paste it again, and the pane says why.
    case needsKey(reconnect: Bool)
}

/// Which device the AI strings name. The Mac's strings say "on this Mac" and point at the menu bar
/// ("Lineform ▸ Connect Your AI…"); the iPhone shows its own variants, which never name a Mac.
/// Both variants compile on both platforms, so each catalog key stays in use everywhere.
enum AIDeviceWording {
    static var namesPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

/// Copy and display decisions for Connect Your AI, kept out of the view so they can be
/// tested without a window. Every string is chrome and localizes; brand and company names
/// do not.
public enum ConnectAIPresentation {
    /// Also the name `AIClientError` messages point writers to ("Check it in Connect Your AI"),
    /// in every language. `ConnectAIPresentationTests` asserts the two agree.
    public static var title: String { title(bundle: .module) }
    static func title(bundle: Bundle) -> String {
        String(localized: "Connect Your AI", bundle: bundle)
    }

    public static var createKeyTitle: String { String(localized: "Create an API key", bundle: .module) }
    public static var keyLabel: String { String(localized: "API key", bundle: .module) }
    public static var addressLabel: String { String(localized: "Address", bundle: .module) }
    public static var optionalKeyLabel: String { String(localized: "API key (optional)", bundle: .module) }
    public static var optionalModelLabel: String { String(localized: "Model (optional)", bundle: .module) }
    public static var connectedText: String { String(localized: "Connected", bundle: .module) }
    public static var disconnectTitle: String { String(localized: "Disconnect", bundle: .module) }
    public static var reconnectNote: String {
        String(localized: "Lineform can't find this key in your Keychain. Paste it again to reconnect.", bundle: .module)
    }

    public static var privacyNote: String { privacyNote(bundle: .module) }
    static func privacyNote(bundle: Bundle) -> String {
        String(localized: "Lineform sends only the text you act on, only when you choose an AI action, directly to the provider you connected, under your account and that provider's terms. Lineform's developer receives nothing.", bundle: bundle)
    }

    public static func billingNote(for provider: AIProvider, bundle: Bundle = .lineformCore) -> String {
        switch provider {
        case .claude:
            return String(localized: "A Claude Pro or Max subscription doesn't cover this. API keys are billed per use by Anthropic.", bundle: bundle)
        case .chatGPT:
            return String(localized: "A ChatGPT Plus or Pro subscription doesn't cover this. API keys are billed per use by OpenAI.", bundle: bundle)
        case .google:
            return String(localized: "A Gemini subscription doesn't cover this. API keys are billed per use by Google.", bundle: bundle)
        case .other:
            guard !AIDeviceWording.namesPhone else {
                return String(localized: "Use a model you run yourself — Ollama, LM Studio, llama.cpp — or any OpenAI-compatible server.", bundle: bundle)
            }
            return String(localized: "Use a model on this Mac — Ollama, LM Studio, llama.cpp — or any OpenAI-compatible server.", bundle: bundle)
        }
    }

    /// One line under "Create an API key": how to make a key that can do as little as possible.
    public static func keyGuidance(for provider: AIProvider, bundle: Bundle = .lineformCore) -> String? {
        switch provider {
        case .chatGPT:
            return String(localized: "Choose Restricted, set Model capabilities to Request, and leave everything else off.", bundle: bundle)
        case .claude, .google:
            return String(localized: "Make a key just for Lineform, and set a monthly spend limit.", bundle: bundle)
        case .other:
            return nil
        }
    }

    public static var modelLabel: String { String(localized: "Model", bundle: .module) }

    /// The consent step's button: just "Connect". What is sent and to whom is the small text
    /// under it (`consentNote`).
    public static var connectTitle: String { String(localized: "Connect", bundle: .module) }

    /// The small text under Connect: what is sent and to whom (the company, or Other's host),
    /// then the privacy note.
    public static func consentNote(for provider: AIProvider, otherHost: String?) -> String {
        recipientNote(for: provider, otherHost: otherHost) + " " + privacyNote
    }

    /// What is sent and to whom: "Lineform will send the text you choose to Anthropic."
    public static func recipientNote(for provider: AIProvider, otherHost: String?, bundle: Bundle = .lineformCore) -> String {
        let host = otherHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let recipient = provider.companyName ?? (host.isEmpty ? nil : host) else {
            return String(localized: "Lineform will send the text you choose to that address.", bundle: bundle)
        }
        return String(localized: "Lineform will send the text you choose to \(recipient).", bundle: bundle)
    }

    /// The host of what the writer has typed into Other's Address field, for the consent
    /// button. Nil until it parses as an address with a host.
    public static func host(fromAddress address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
        return host
    }

    public static func paneState(for provider: AIProvider, connectedProvider: AIProvider?,
                          keyMissing: Bool) -> ConnectAIPaneState {
        guard provider == connectedProvider else { return .needsKey(reconnect: false) }
        return keyMissing ? .needsKey(reconnect: true) : .connected
    }

    /// The list row's checkmark. A provider whose key went missing is not shown as connected.
    public static func showsConnectedMark(for provider: AIProvider, connectedProvider: AIProvider?,
                                   keyMissing: Bool) -> Bool {
        paneState(for: provider, connectedProvider: connectedProvider, keyMissing: keyMissing) == .connected
    }
}
