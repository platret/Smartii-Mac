import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing provider API keys.
/// Uses a generic-password item keyed by `account` under a single service.
enum Keychain {
    /// The Keychain service all Smartii items live under.
    private static let service = "app.smartii.mac"

    /// Store (or replace) the string `value` for the given `account`.
    /// Implemented as delete-then-add so updates are idempotent.
    static func set(_ value: String, account: String) {
        delete(account: account)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    /// Fetch the stored string for `account`, or nil if absent / unreadable.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove the stored item for `account` (no-op if it does not exist).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

/// App-wide settings: non-secret values in UserDefaults, API keys in the Keychain.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let provider = "provider"
        static let model = "model"
        static let autoCopyAnswer = "autoCopyAnswer"
    }

    private init() {}

    /// Selected provider id (default "gemini").
    var providerId: String {
        get { defaults.string(forKey: Key.provider) ?? "gemini" }
        set { defaults.set(newValue, forKey: Key.provider) }
    }

    /// Selected model id; empty string means "use the provider default".
    var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Whether to auto-copy answers to the clipboard.
    /// Defaults to true when the key has never been written.
    var autoCopyAnswer: Bool {
        get {
            // A missing key must be treated as `true`; UserDefaults.bool
            // returns false for missing keys, so check existence first.
            if defaults.object(forKey: Key.autoCopyAnswer) == nil { return true }
            return defaults.bool(forKey: Key.autoCopyAnswer)
        }
        set { defaults.set(newValue, forKey: Key.autoCopyAnswer) }
    }

    /// Read the API key for a provider from the Keychain.
    func apiKey(for providerId: String) -> String? {
        Keychain.get(account: "key.\(providerId)")
    }

    /// Persist the API key for a provider into the Keychain.
    func setAPIKey(_ key: String, for providerId: String) {
        Keychain.set(key, account: "key.\(providerId)")
    }
}
