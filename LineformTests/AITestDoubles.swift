import Foundation
@testable import Lineform

/// Keychain stand-in. Counts reads so tests can prove nothing touches secrets early.
final class InMemoryAIKeychain: AIKeychain {
    private var keys: [AIProvider: String] = [:]
    private(set) var readCount = 0
    var failWrites = false

    func readKey(for provider: AIProvider) -> String? {
        readCount += 1
        return keys[provider]
    }

    @discardableResult
    func writeKey(_ key: String, for provider: AIProvider) -> Bool {
        guard !failWrites else { return false }
        keys[provider] = key
        return true
    }

    func deleteKey(for provider: AIProvider) {
        keys[provider] = nil
    }
}
