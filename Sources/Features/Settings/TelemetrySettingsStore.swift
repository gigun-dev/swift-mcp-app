import Foundation
import Observation
import Security
import Services

/// OTLP endpointはUserDefaults、任意headerはKeychainに分けて保存する。
/// backend固有の認証方式は解釈せず、OTel標準形式の`name=value,name2=value2`をexporterへ渡す。
@MainActor
@Observable
final class TelemetrySettingsStore {
    var endpoint: String
    var headers: String

    private let defaults: UserDefaults
    private static let endpointKey = "telemetry.otlp.endpoint"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        headers = TelemetryKeychain.load(account: "headers") ?? Self.migratedLegacyHeaders()
    }

    var configuration: OpenTelemetryConfiguration? {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return OpenTelemetryConfiguration(endpoint: url, headers: parsedHeaders)
    }

    func save() {
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.endpointKey)
        TelemetryKeychain.save(headers, account: "headers")
        TelemetryKeychain.save("", account: "public-key")
        TelemetryKeychain.save("", account: "secret-key")
    }

    private var parsedHeaders: [(String, String)] {
        headers.split(separator: ",").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || value.isEmpty ? nil : (name, value)
        }
    }

    /// 旧版のLangfuse pk/skを、一度だけ汎用header表現へ持ち上げる。
    private static func migratedLegacyHeaders() -> String {
        guard let publicKey = TelemetryKeychain.load(account: "public-key"),
              let secretKey = TelemetryKeychain.load(account: "secret-key"),
              !publicKey.isEmpty, !secretKey.isEmpty else { return "" }
        let credentials = Data("\(publicKey):\(secretKey)".utf8).base64EncodedString()
        return "Authorization=Basic \(credentials),x-langfuse-ingestion-version=4"
    }
}

private enum TelemetryKeychain {
    private static let service = "dev.gigun.mcphost.telemetry"

    static func save(_ value: String, account: String) {
        let query = baseQuery(account: account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData] = data
            addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addition as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
