// Forge — Keychain-backed secret storage. The Hugging Face token lives here,
// never in a plaintext settings file.

import Foundation
import Security

enum SecretsStore {
    private static let service = "com.forge.mlx"
    private static let hfAccount = "huggingface-token"
    private static let anthropicAccount = "anthropic-api-key"
    private static let openRouterAccount = "openrouter-api-key"

    static var huggingFaceToken: String? {
        get { read(account: hfAccount) }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                write(account: hfAccount, value: newValue.trimmingCharacters(in: .whitespaces))
            } else {
                delete(account: hfAccount)
            }
        }
    }

    static var anthropicAPIKey: String? {
        get { read(account: anthropicAccount) }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                write(account: anthropicAccount, value: newValue.trimmingCharacters(in: .whitespaces))
            } else {
                delete(account: anthropicAccount)
            }
        }
    }

    static var openRouterAPIKey: String? {
        get { read(account: openRouterAccount) }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                write(account: openRouterAccount, value: newValue.trimmingCharacters(in: .whitespaces))
            } else {
                delete(account: openRouterAccount)
            }
        }
    }

    private static func read(account: String) -> String? {
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

    private static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
