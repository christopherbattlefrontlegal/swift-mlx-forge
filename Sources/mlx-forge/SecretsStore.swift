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
        var localServerAPIKey: String? = nil
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
        get { read { normalized($0.huggingFace) } }
        set { mutate { $0.huggingFace = normalized(newValue) } }
    }

    static var anthropicAPIKey: String? {
        get { read { normalized($0.anthropic) } }
        set { mutate { $0.anthropic = normalized(newValue) } }
    }

    static var openRouterAPIKey: String? {
        get { read { normalized($0.openRouter) } }
        set { mutate { $0.openRouter = normalized(newValue) } }
    }

    static var openAIAPIKey: String? {
        get { read { normalized($0.openAI) } }
        set { mutate { $0.openAI = normalized(newValue) } }
    }

    static var braveSearchAPIKey: String? {
        get { read { normalized($0.braveSearch) } }
        set { mutate { $0.braveSearch = normalized(newValue) } }
    }

    static var hasHuggingFaceToken: Bool { read { normalized($0.huggingFace) != nil } }
    static var hasAnthropicKey: Bool { read { normalized($0.anthropic) != nil } }
    static var hasOpenRouterKey: Bool { read { normalized($0.openRouter) != nil } }
    static var hasOpenAIKey: Bool { read { normalized($0.openAI) != nil } }
    static var hasBraveSearchKey: Bool { read { normalized($0.braveSearch) != nil } }

    /// Lazily creates a 256-bit bearer token for authenticating LAN API
    /// requests. A token is returned only after it has been verified in the
    /// Keychain, so callers never advertise an ephemeral credential.
    static var localServerAPIKey: String? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        if let existing = normalized(bundle.localServerAPIKey) {
            return existing
        }
        guard let generated = generateServerAPIKey() else { return nil }
        var candidate = bundle
        candidate.localServerAPIKey = generated
        guard persistBundle(candidate) else { return nil }
        bundle = candidate
        return generated
    }

    static var hasLocalServerAPIKey: Bool {
        read { normalized($0.localServerAPIKey) != nil }
    }

    // MARK: - Load / persist

    private static func loadBundle() {
        if let data = readKeychainData(account: bundleAccount),
            let decoded = try? JSONDecoder().decode(Bundle.self, from: data)
        {
            bundle = decoded
            return
        }

        // One-time migration from older per-item Keychain layout.
        let migrated = Bundle(
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
        if hasAny, persistBundle(migrated) {
            // Delete legacy items only after the bundled value was written and
            // read back byte-for-byte from the Keychain.
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
        ensureLoaded()
        var candidate = bundle
        edit(&candidate)
        if persistBundle(candidate) {
            bundle = candidate
        }
    }

    private static func read<T>(_ body: (Bundle) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        return body(bundle)
    }

    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        loadBundle()
    }

    private static func persistBundle(_ value: Bundle) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
            writeKeychain(account: bundleAccount, data: data),
            readKeychainData(account: bundleAccount) == data
        else { return false }
        return true
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

    @discardableResult
    private static func writeKeychain(account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
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

    private static func generateServerAPIKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
