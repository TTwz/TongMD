import Foundation
import Security

enum Keychain {
    static let service = "dev.tong.TongMD"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let base = query(account)
        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return true
        }

        let data = Data(value.utf8)
        // 先尝试更新，避免「删除 + 新增」在 ACL 或并发下失败还静默无感
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        // 更新失败时退回「删了重建」
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String {
        var item: CFTypeRef?
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
