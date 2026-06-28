// Forge — Keychain-backed secret storage. API keys and tokens live here,
// never in a plaintext settings file. Loaded once per process into memory so
// SwiftUI re-renders don't hammer the Keychain (which prompts for your login
// password on every item access when the chain is locked).

import Foundation
import Security

enum SecretsStore {
    private static let service = "com.forge.mlx"
    private static let bundleAccount = "forge-secrets-v1"

    // Legacy per-secret accounts — migrated into the bundle on first read.
    private static let hfAccount = "huggingface-token"
    private static let anthropicAccount = "anthropic-api-key"
    private static let openRouterAccount = "openrouter-api-key"
    private static let braveSearchAccount = "brave-search-api-key"
    private static let openAIAccount = "openai-api-key"

    private struct Bundle: Codable {
        var huggingFace: String?
        var anthropic: String?
        var openRouter: String?
        var braveSearch: String?
        var openAI: String?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var loaded = false
    private nonisolated(unsafe) static var bundle = Bundle()

    /// Call once early in app startup. Idempotent — safe to call many times.
    static func warmCache() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        loadBundle()
    }

    static var huggingFaceToken: String? {
        get { trimmed(bundle.huggingFace) }
        set { mutate { $0.huggingFace = normalized(newValue) } }
    }

    static var anthropicAPIKey: String? {
        get { trimmed(bundle.anthropic) }
        set { mutate { $0.anthropic = normalized(newValue) } }
    }

    static var openRouterAPIKey: String? {
        get { trimmed(bundle.openRouter) }
        set { mutate { $0.openRouter = normalized(newValue) } }
    }

    static var openAIAPIKey: String? {
        get { trimmed(bundle.openAI) }
        set { mutate { $0.openAI = normalized(newValue) } }
    }

    static var braveSearchAPIKey: String? {
        get { trimmed(bundle.braveSearch) }
        set { mutate { $0.braveSearch = normalized(newValue) } }
    }

    static var hasHuggingFaceToken: Bool { isStored(bundle.huggingFace) }
    static var hasAnthropicKey: Bool { isStored(bundle.anthropic) }
    static var hasOpenRouterKey: Bool { isStored(bundle.openRouter) }
    static var hasOpenAIKey: Bool { isStored(bundle.openAI) }
    static var hasBraveSearchKey: Bool { isStored(bundle.braveSearch) }

    // MARK: - Load / persist

    private static func loadBundle() {
        if let data = readKeychainData(account: bundleAccount),
            let decoded = try? JSONDecoder().decode(Bundle.self, from: data)
        {
            bundle = decoded
            return
        }

        // One-time migration from older per-item Keychain layout.
        var migrated = Bundle(
            huggingFace: readKeychainString(account: hfAccount),
            anthropic: readKeychainString(account: anthropicAccount),
            openRouter: readKeychainString(account: openRouterAccount),
            braveSearch: readKeychainString(account: braveSearchAccount),
            openAI: readKeychainString(account: openAIAccount)
        )
        let hasAny = [
            migrated.huggingFace, migrated.anthropic, migrated.openRouter,
            migrated.braveSearch, migrated.openAI,
        ].contains { normalized($0) != nil }

        bundle = migrated
        if hasAny {
            persistBundle()
            deleteKeychain(account: hfAccount)
            deleteKeychain(account: anthropicAccount)
            deleteKeychain(account: openRouterAccount)
            deleteKeychain(account: braveSearchAccount)
            deleteKeychain(account: openAIAccount)
        }
    }

    private static func mutate(_ edit: (inout Bundle) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !loaded { loaded = true; loadBundle() }
        edit(&bundle)
        persistBundle()
    }

    private static func persistBundle() {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        writeKeychain(account: bundleAccount, data: data)
    }

    // MARK: - Keychain primitives

    private static func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return data
    }

    private static func readKeychainString(account: String) -> String? {
        guard let data = readKeychainData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmed(_ value: String?) -> String? {
        warmCache()
        return normalized(value)
    }

    private static func isStored(_ value: String?) -> Bool {
        warmCache()
        return normalized(value) != nil
    }
}