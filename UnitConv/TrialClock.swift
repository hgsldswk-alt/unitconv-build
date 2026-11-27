import Foundation
import Security

enum TrialClock {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.unitconv",
        kSecAttrAccount as String: "paid-first-open"
    ]

    static func start(proposed: Date) -> Date {
        if let saved = read() { return saved }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(String(proposed.timeIntervalSince1970).utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return read() ?? proposed }
        return proposed
    }

    private static func read() -> Date? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let seconds = String(data: data, encoding: .utf8).flatMap(Double.init),
              seconds.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
