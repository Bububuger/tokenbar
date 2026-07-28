import Foundation
import Security

enum CursorCredentialStoreError: Error {
    case emptyCredential
    case unavailable
}

/// Stores the opt-in Cursor Dashboard cookie outside UserDefaults and the
/// TokenBar database. Callers must never include the returned value in logs or
/// user-facing error messages.
struct CursorCredentialStore: @unchecked Sendable {
    static let service = "com.javis.TokenBar.cursor-dashboard"
    static let account = "cookie"

    func save(_ cookieHeader: String) throws {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerLines = trimmed.split(whereSeparator: \.isNewline)
        let cookieValue: String
        if let cookieLine = headerLines.first(where: {
            $0.lowercased().hasPrefix("cookie:")
        }) {
            cookieValue = String(cookieLine.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if headerLines.count <= 1 {
            cookieValue = trimmed
        } else {
            cookieValue = ""
        }
        guard !cookieValue.isEmpty, let data = cookieValue.data(using: .utf8) else {
            throw CursorCredentialStoreError.emptyCredential
        }

        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CursorCredentialStoreError.unavailable
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CursorCredentialStoreError.unavailable
        }
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw CursorCredentialStoreError.unavailable
        }
        return value
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CursorCredentialStoreError.unavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
