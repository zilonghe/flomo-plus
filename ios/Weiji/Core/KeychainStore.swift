import Foundation
import Security

@MainActor
struct KeychainStore {
    let read: (String, String) -> String?
    let write: (String, String, String) throws -> Void

    static let live = Self(read: load, write: save)

    func serverToken(for origin: String) -> String? { read(origin, "server") }
    func saveServerToken(_ token: String, for origin: String) throws { try write(token, origin, "server") }

    func openAIKey(origin: String, userId: String) -> String? {
        read(origin, openAIKind(userId))
    }

    func saveOpenAIKey(_ key: String, origin: String, userId: String) throws {
        try write(key, origin, openAIKind(userId))
    }

    // An origin-only key has no verified owner and must never be read as a fallback.
    private func openAIKind(_ userId: String) -> String { "openai:\(userId)" }

    private static func query(origin: String, kind: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.zilonghe.weiji." + kind,
         kSecAttrAccount as String: origin]
    }

    private static func load(origin: String, kind: String) -> String? {
        var query = query(origin: origin, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ secret: String, origin: String, kind: String) throws {
        var query = query(origin: origin, kind: kind)
        if secret.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法保存连接凭据（\(status)）。" }
    }
}
