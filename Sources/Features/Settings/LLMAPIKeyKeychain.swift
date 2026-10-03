import Foundation
import OSLog
import Security

enum LLMAPIKeyKeychain {
    private static let service = "dev.gigun.mcphost.llm"
    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "llm-settings")

    @discardableResult
    static func save(_ key: String, account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account: account)
            return true
        }
        let query = baseQuery(account: account)
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.notice("LLMキーのKeychain保存失敗(status \(addStatus)): メモリ値で続行")
                return false
            }
        } else if updateStatus != errSecSuccess {
            logger.notice("LLMキーのKeychain更新失敗(status \(updateStatus)): メモリ値で続行")
            return false
        }
        return true
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        guard let key = String(bytes: data, encoding: .utf8) else { return nil }
        return key.isEmpty ? nil : key
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
