// Forge — secret storage under Application Support.
//
// Keys live in ~/Library/Application Support/Forge/secrets.json (mode 0600).
// A one-time migration copies any legacy Keychain entries into that file so
// ad-hoc rebuilds (new code signature each time) don't spam the login password
// dialog on every launch.

import Foundation
import Security

enum SecretsStore {
    private static let service = "com.forge.mlx"
    private static let migrationFlag = "secrets.migratedFromKeychain.v1"

    private static let hfAccount = "huggingface-token"
    private static let anthropicAccount = "anthropic-api-key"
    private static let openRouterAccount = "openrouter-api-key"

    private struct SecretsFile: Codable {
        var huggingFaceToken: String?
        var anthropicAPIKey: String?
        var openRouterAPIKey: String?
    }

    static var huggingFaceToken: String? {
        get { load().huggingFaceToken }
        set {
            var secrets = load()
            secrets.huggingFaceToken = normalize(newValue)
            writeFile(secrets)
        }
    }

    static var anthropicAPIKey: String? {
        get { load().anthropicAPIKey }
        set {
            var secrets = load()
            secrets.anthropicAPIKey = normalize(newValue)
            writeFile(secrets)
        }
    }

    static var openRouterAPIKey: String? {
        get { load().openRouterAPIKey }
        set {
            var secrets = load()
            secrets.openRouterAPIKey = normalize(newValue)
            writeFile(secrets)
        }
    }

    /// Call once at launch before reading secrets.
    static func migrateLegacyKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return }

        var secrets = readFile() ?? SecretsFile()
        var changed = false

        if secrets.huggingFaceToken == nil, let legacy = readKeychain(account: hfAccount) {
            secrets.huggingFaceToken = legacy
            changed = true
        }
        if secrets.anthropicAPIKey == nil, let legacy = readKeychain(account: anthropicAccount) {
            secrets.anthropicAPIKey = legacy
            changed = true
        }
        if secrets.openRouterAPIKey == nil, let legacy = readKeychain(account: openRouterAccount) {
            secrets.openRouterAPIKey = legacy
            changed = true
        }

        if changed {
            writeFile(secrets)
        }

        deleteKeychain(account: hfAccount)
        deleteKeychain(account: anthropicAccount)
        deleteKeychain(account: openRouterAccount)

        UserDefaults.standard.set(true, forKey: migrationFlag)
    }

    // MARK: - File store

    private static func load() -> SecretsFile {
        readFile() ?? SecretsFile()
    }

    private static func readFile() -> SecretsFile? {
        let url = ForgePaths.secretsFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SecretsFile.self, from: data)
    }

    private static func writeFile(_ secrets: SecretsFile) {
        let url = ForgePaths.secretsFile
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort — settings UI still reflects in-memory state until retry.
        }
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Legacy Keychain (migration only)

    private static func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}