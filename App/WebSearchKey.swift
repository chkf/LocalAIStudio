import Foundation
import Security

enum WebSearchKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.example.localaistudio.web-search",
         kSecAttrAccount as String: "brave"]
    }

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WebToolError.invalid("无法从钥匙串读取搜索 Key。")
        }
        return value
    }

    static func save(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\n"), !value.contains("\r") else { throw WebToolError.invalid("搜索 Key 格式无效。") }
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let data = Data(value.utf8)
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = updated }
        }
        guard status == errSecSuccess || (value.isEmpty && status == errSecItemNotFound) else {
            throw WebToolError.invalid("无法保存搜索 Key 到钥匙串。")
        }
    }
}
