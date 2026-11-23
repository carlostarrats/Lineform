import Foundation
import Security

/// What reading the stored device name found.
public enum HistoryDeviceIDRead: Equatable, Sendable {
    case found(String)
    case notFound
    /// The store could not be asked (a Keychain error other than "no such item").
    case unavailable
}

/// Where this device's History name is kept. It must NOT travel with a backup restore or
/// Migration Assistant: two live devices with one name would write one record file (plan D1).
/// Production: the Keychain, this device only. Tests: an in-memory double.
public protocol HistoryDeviceIDStoring: AnyObject {
    func readDeviceID() -> HistoryDeviceIDRead
    @discardableResult func writeDeviceID(_ id: String) -> Bool
}

/// A generic-password item, service `<bundle id>.history-device`, accessible after first unlock
/// on THIS device only and never synchronised, so neither iCloud Keychain, an encrypted backup
/// nor Migration Assistant carries it to another device. Legacy file keychain on the Mac (no
/// data-protection keychain, no new entitlement), like `SystemAIKeychain`.
public final class SystemHistoryDeviceIDKeychain: HistoryDeviceIDStoring, @unchecked Sendable {
    private let service: String
    private static let account = "device"

    public init(service: String = (Bundle.main.bundleIdentifier ?? "com.lineform.app") + ".history-device") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func readDeviceID() -> HistoryDeviceIDRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let id = String(data: data, encoding: .utf8) else { return .unavailable }
            return .found(id)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    @discardableResult
    public func writeDeviceID(_ id: String) -> Bool {
        let data = Data(id.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// This device's name in shared History: `"<platform>-<UUID>"` (`mac-…`, `iphone-…`), made once.
/// It is also the file name of this device's records, so a Mac's and an iPhone's names never
/// match.
///
/// Kept in `storage` (the Keychain, this device only). A name 1.9-era builds kept in user
/// defaults (`LineformHistoryDeviceID.v1`, which a backup restore copies to a new device) is
/// moved there once and removed from defaults. When the Keychain cannot be used, the name lives
/// in defaults instead, so it is still the same name at every launch.
///
/// `salt` (the Mac's hardware hash, passed in by the app) is appended: `mac-<UUID>-<salt>`. The
/// Mac's Keychain is the legacy file keychain, which Migration Assistant and Time Machine carry to
/// a new Mac, so the stored part alone could be shared by two live Macs. No salt: the stored name.
public enum HistoryDeviceIdentity {
    static let defaultsKey = "LineformHistoryDeviceID.v1"

    public static func current(platform: String, storage: HistoryDeviceIDStoring, defaults: UserDefaults,
                               salt: String? = nil) -> String {
        let stored = storedName(platform: platform, storage: storage, defaults: defaults)
        guard let salt, !salt.isEmpty else { return stored }
        return "\(stored)-\(salt)"
    }

    private static func storedName(platform: String, storage: HistoryDeviceIDStoring, defaults: UserDefaults) -> String {
        let prefix = platform + "-"
        let legacy = defaults.string(forKey: defaultsKey).flatMap { $0.hasPrefix(prefix) ? $0 : nil }
        switch storage.readDeviceID() {
        case let .found(id) where id.hasPrefix(prefix):
            if defaults.object(forKey: defaultsKey) != nil { defaults.removeObject(forKey: defaultsKey) }
            return id
        case .unavailable:
            if let legacy { return legacy }
            let made = "\(prefix)\(UUID().uuidString)"
            defaults.set(made, forKey: defaultsKey)
            return made
        case .found, .notFound:
            if let legacy {
                if storage.writeDeviceID(legacy) { defaults.removeObject(forKey: defaultsKey) }
                return legacy
            }
            let made = "\(prefix)\(UUID().uuidString)"
            if !storage.writeDeviceID(made) { defaults.set(made, forKey: defaultsKey) }
            return made
        }
    }
}

/// The device name, worked out at its first use (a shared document's first load or save), never
/// when the store is made.
final class LazyDeviceName: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> String
    private var made: String?

    init(_ make: @escaping () -> String) { self.make = make }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        if let made { return made }
        let name = make()
        made = name
        return name
    }
}
