import Foundation
import Security

public struct GeminiAPIKeyRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public let lastFour: String
    public var isEnabled: Bool
    public let createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        lastFour: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.lastFour = lastFour
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct GeminiAPIKeyCredential: Hashable, Sendable {
    public let id: UUID
    public let apiKey: String

    public init(id: UUID, apiKey: String) {
        self.id = id
        self.apiKey = apiKey
    }
}

public enum GeminiAPIKeyStoreError: Error, LocalizedError, Hashable, Sendable {
    case emptyKey
    case invalidKey
    case duplicateKey
    case missingSecret
    case keychainFailure(OSStatus)
    case metadataFailure

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter a Google Gemini API key before adding it."
        case .invalidKey:
            return "That does not look like a valid Google Gemini API key. Paste the complete key without spaces or line breaks."
        case .duplicateKey:
            return "That Gemini API key is already saved."
        case .missingSecret:
            return "Tare found the key's saved label but not its Keychain secret. Remove that entry and add the key again."
        case .keychainFailure(let status):
            return "macOS Keychain could not save the Gemini API key (status \(status))."
        case .metadataFailure:
            return "Tare could not read its Gemini API key list."
        }
    }
}

/// Keychain work is dispatched off the app's main actor by the macOS client.
/// UserDefaults and Security's item APIs are safe to use from that worker
/// context, and the unchecked marker keeps the credential value scoped to the
/// operation that requested it.
public final class GeminiAPIKeyStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let metadataKey: String
    private let keychainService: String

    public init(
        defaults: UserDefaults = .standard,
        metadataKey: String = "geminiAPIKeys.v1",
        keychainService: String = "com.tejas.Tare.gemini-api-key"
    ) {
        self.defaults = defaults
        self.metadataKey = metadataKey
        self.keychainService = keychainService
    }

    public var records: [GeminiAPIKeyRecord] {
        (try? loadRecords()) ?? []
    }

    /// Reads metadata without silently turning a damaged preferences record
    /// into an empty key list that could overwrite the user's inventory.
    public func loadRecords() throws -> [GeminiAPIKeyRecord] {
        guard let data = defaults.data(forKey: metadataKey) else { return [] }
        do {
            return try JSONDecoder().decode([GeminiAPIKeyRecord].self, from: data)
        } catch {
            throw GeminiAPIKeyStoreError.metadataFailure
        }
    }

    @discardableResult
    public func add(label: String, apiKey: String) throws -> GeminiAPIKeyRecord {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw GeminiAPIKeyStoreError.emptyKey }
        guard normalizedKey.count >= 8,
              !normalizedKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GeminiAPIKeyStoreError.invalidKey
        }

        let existingRecords = try loadRecords()
        for record in existingRecords {
            if let existingKey = try secret(for: record.id), existingKey == normalizedKey {
                throw GeminiAPIKeyStoreError.duplicateKey
            }
        }

        let record = GeminiAPIKeyRecord(
            label: Self.normalizedLabel(label),
            lastFour: String(normalizedKey.suffix(4))
        )
        try writeSecret(normalizedKey, for: record.id)
        var updatedRecords = existingRecords
        updatedRecords.append(record)
        do {
            try save(updatedRecords)
        } catch {
            try? deleteSecret(for: record.id)
            throw error
        }
        return record
    }

    public func delete(_ record: GeminiAPIKeyRecord) throws {
        let existingRecords = try loadRecords()
        guard existingRecords.contains(where: { $0.id == record.id }) else { return }

        // Save metadata first, and restore it if Keychain deletion fails, so
        // a transient Keychain error cannot silently lose the saved entry.
        try save(existingRecords.filter { $0.id != record.id })
        do {
            try deleteSecret(for: record.id)
        } catch {
            try? save(existingRecords)
            throw error
        }
    }

    public func setEnabled(_ isEnabled: Bool, for record: GeminiAPIKeyRecord) throws {
        var updatedRecords = try loadRecords()
        guard let index = updatedRecords.firstIndex(where: { $0.id == record.id }) else { return }
        if isEnabled, try secret(for: record.id) == nil {
            throw GeminiAPIKeyStoreError.missingSecret
        }
        updatedRecords[index].isEnabled = isEnabled
        try save(updatedRecords)
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) throws {
        var updatedRecords = try loadRecords()
        let movingIndices = fromOffsets.sorted()
        let moving = movingIndices.compactMap { index in
            updatedRecords.indices.contains(index) ? updatedRecords[index] : nil
        }
        for index in movingIndices.reversed() where updatedRecords.indices.contains(index) {
            updatedRecords.remove(at: index)
        }
        let removedBeforeDestination = movingIndices.filter { $0 < toOffset }.count
        let destination = min(max(0, toOffset - removedBeforeDestination), updatedRecords.count)
        updatedRecords.insert(contentsOf: moving, at: destination)
        try save(updatedRecords)
    }

    public func activeCredentials() throws -> [GeminiAPIKeyCredential] {
        try loadRecords()
            .filter(\.isEnabled)
            .compactMap { record in
                guard let apiKey = try secret(for: record.id) else { return nil }
                return GeminiAPIKeyCredential(id: record.id, apiKey: apiKey)
            }
    }

    public func markUsed(_ id: UUID) {
        guard var updatedRecords = try? loadRecords() else { return }
        guard let index = updatedRecords.firstIndex(where: { $0.id == id }) else { return }
        updatedRecords[index].lastUsedAt = Date()
        try? save(updatedRecords)
    }

    private func secret(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GeminiAPIKeyStoreError.keychainFailure(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw GeminiAPIKeyStoreError.keychainFailure(errSecDecode)
        }
        return value
    }

    private func writeSecret(_ value: String, for id: UUID) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: id)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GeminiAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GeminiAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    private func save(_ records: [GeminiAPIKeyRecord]) throws {
        guard let data = try? JSONEncoder().encode(records) else {
            throw GeminiAPIKeyStoreError.metadataFailure
        }
        defaults.set(data, forKey: metadataKey)
        guard defaults.data(forKey: metadataKey) == data else {
            throw GeminiAPIKeyStoreError.metadataFailure
        }
    }

    private static func normalizedLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Google Gemini key" }
        return String(trimmed.prefix(80))
    }
}
