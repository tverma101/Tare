import Foundation
import Security

/// Stores the local FreeLLMAPI unified key without putting it in preferences,
/// transcript metadata, logs, or a packaged Tare artifact.
public final class FreeLLMAPIKeyStore: @unchecked Sendable {
    public static let defaultService = "com.tejas.Tare.freellmapi"
    public static let defaultAccount = "unified"

    private let service: String
    private let account: String

    public init(
        service: String = FreeLLMAPIKeyStore.defaultService,
        account: String = FreeLLMAPIKeyStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var query = baseQuery(suppressAuthenticationUI: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Export-time reads must never put up a modal Keychain prompt. A
        // signed Tare build has a stable designated requirement and can read
        // its own item silently; an item requiring user interaction simply
        // causes the naming feature to fall back to local filename cleanup.

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw FreeLLMAPIKeyStoreError.keychainFailure(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw FreeLLMAPIKeyStoreError.keychainFailure(errSecDecode)
        }
        return value
    }

    public var hasKey: Bool {
        (try? load())?.isEmpty == false
    }

    public func save(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FreeLLMAPIKeyStoreError.emptyKey }
        guard !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw FreeLLMAPIKeyStoreError.invalidKey
        }

        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(suppressAuthenticationUI: true) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw FreeLLMAPIKeyStoreError.keychainFailure(updateStatus)
        }

        var addQuery = baseQuery()
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FreeLLMAPIKeyStoreError.keychainFailure(addStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery(suppressAuthenticationUI: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FreeLLMAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(suppressAuthenticationUI: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if suppressAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        return query
    }
}

public enum FreeLLMAPIKeyStoreError: Error, LocalizedError, Hashable, Sendable {
    case emptyKey
    case invalidKey
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter the FreeLLMAPI unified API key before saving it."
        case .invalidKey:
            return "The FreeLLMAPI key cannot contain spaces or line breaks."
        case .keychainFailure(let status):
            return "macOS Keychain operation failed (status \(status))."
        }
    }
}
