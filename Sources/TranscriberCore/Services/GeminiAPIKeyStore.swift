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
    /// The saved record's label. Messages that name a credential use this
    /// instead of the key, which must never reach a log or the UI.
    public let label: String

    public init(id: UUID, apiKey: String, label: String = "Gemini key") {
        self.id = id
        self.apiKey = apiKey
        self.label = label
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
    /// Every mutation is a read-modify-write cycle over one preferences blob,
    /// and the macOS client dispatches several of them from detached workers.
    /// Serializing them here keeps a `markUsed` from writing back a snapshot
    /// taken before the user's reorder, silently undoing it.
    private static let mutationQueue = DispatchQueue(label: "com.tejas.Tare.gemini-api-key-metadata")

    private let defaults: UserDefaults
    private let metadataKey: String
    private let keychainService: String

    /// Secrets copied into the data-protection Keychain whose legacy copy could
    /// not be removed yet. Guarded by `mutationQueue`.
    private var pendingLegacyCleanup: Set<UUID> = []

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
        try Self.mutationQueue.sync { try readRecords() }
    }

    @discardableResult
    public func add(label: String, apiKey: String) throws -> GeminiAPIKeyRecord {
        try Self.mutationQueue.sync { try insertRecord(label: label, apiKey: apiKey) }
    }

    public func delete(_ record: GeminiAPIKeyRecord) throws {
        try Self.mutationQueue.sync { try removeRecord(record) }
    }

    public func setEnabled(_ isEnabled: Bool, for record: GeminiAPIKeyRecord) throws {
        try Self.mutationQueue.sync { try setEnabledLocked(isEnabled, for: record) }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) throws {
        try Self.mutationQueue.sync { try moveLocked(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    public func activeCredentials() throws -> [GeminiAPIKeyCredential] {
        try Self.mutationQueue.sync { try activeCredentialsLocked() }
    }

    public func markUsed(_ id: UUID) {
        Self.mutationQueue.sync {
            guard var updatedRecords = try? readRecords() else { return }
            guard let index = updatedRecords.firstIndex(where: { $0.id == id }) else { return }
            updatedRecords[index].lastUsedAt = Date()
            try? save(updatedRecords)
        }
    }

    // MARK: - Serialized bodies

    // These run while `mutationQueue` is held, so they read through
    // `readRecords` rather than the queue-synchronized `loadRecords`.

    private func readRecords() throws -> [GeminiAPIKeyRecord] {
        guard let data = defaults.data(forKey: metadataKey) else { return [] }
        do {
            return try JSONDecoder().decode([GeminiAPIKeyRecord].self, from: data)
        } catch {
            throw GeminiAPIKeyStoreError.metadataFailure
        }
    }

    private func insertRecord(label: String, apiKey: String) throws -> GeminiAPIKeyRecord {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw GeminiAPIKeyStoreError.emptyKey }
        guard normalizedKey.count >= 8,
              !normalizedKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GeminiAPIKeyStoreError.invalidKey
        }

        let existingRecords = try readRecords()
        for record in existingRecords {
            // Read without migrating: a duplicate check should not perform
            // Keychain maintenance, and must not fail for an unrelated reason.
            if let existingKey = try readSecret(for: record.id, dataProtection: KeychainBackend.usesDataProtection)
                ?? (KeychainBackend.usesDataProtection ? try readSecret(for: record.id, dataProtection: false) : nil),
               existingKey == normalizedKey {
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

    private func removeRecord(_ record: GeminiAPIKeyRecord) throws {
        let existingRecords = try readRecords()
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

    private func setEnabledLocked(_ isEnabled: Bool, for record: GeminiAPIKeyRecord) throws {
        var updatedRecords = try readRecords()
        guard let index = updatedRecords.firstIndex(where: { $0.id == record.id }) else { return }
        if isEnabled, try secret(for: record.id) == nil {
            throw GeminiAPIKeyStoreError.missingSecret
        }
        updatedRecords[index].isEnabled = isEnabled
        try save(updatedRecords)
    }

    private func moveLocked(fromOffsets: IndexSet, toOffset: Int) throws {
        var updatedRecords = try readRecords()
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

    private func activeCredentialsLocked() throws -> [GeminiAPIKeyCredential] {
        try readRecords()
            .filter(\.isEnabled)
            .compactMap { record in
                guard let apiKey = try secret(for: record.id) else { return nil }
                return GeminiAPIKeyCredential(id: record.id, apiKey: apiKey, label: record.label)
            }
    }

    private func secret(for id: UUID) throws -> String? {
        if let value = try readSecret(for: id, dataProtection: KeychainBackend.usesDataProtection) {
            return value
        }

        // A secret saved before this build used the data-protection Keychain is
        // still in the legacy one. Move it across so it stops being eligible for
        // Keychain backup, then answer from the new location.
        guard KeychainBackend.usesDataProtection else { return nil }
        // Retry a cleanup that previously failed before looking for a new copy.
        if pendingLegacyCleanup.contains(id) {
            try? deleteSecret(for: id, dataProtection: false)
            pendingLegacyCleanup.remove(id)
        }
        guard let legacy = try readSecret(for: id, dataProtection: false) else { return nil }

        try writeSecret(legacy, for: id)
        do {
            try deleteSecret(for: id, dataProtection: false)
            pendingLegacyCleanup.remove(id)
        } catch {
            // The copy is already safe in the new Keychain, so the value is not
            // at risk. Remember the leftover so a later read retries, rather
            // than leaving a backup-eligible duplicate behind silently.
            pendingLegacyCleanup.insert(id)
        }
        return legacy
    }

    private func readSecret(for id: UUID, dataProtection: Bool) throws -> String? {
        var query = baseQuery(for: id, dataProtection: dataProtection)
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
        var query = baseQuery(for: id, dataProtection: KeychainBackend.usesDataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = KeychainBackend.secretAccessibility
        query[kSecAttrLabel as String] = "Tare Gemini API key"

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: KeychainBackend.secretAccessibility
            ]
            status = SecItemUpdate(
                baseQuery(for: id, dataProtection: KeychainBackend.usesDataProtection) as CFDictionary,
                attributes as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw GeminiAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteSecret(for id: UUID) throws {
        try deleteSecret(for: id, dataProtection: KeychainBackend.usesDataProtection)
    }

    private func deleteSecret(for id: UUID, dataProtection: Bool) throws {
        let status = SecItemDelete(baseQuery(for: id, dataProtection: dataProtection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GeminiAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(for id: UUID, dataProtection: Bool? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString
        ]
        if let dataProtection {
            KeychainBackend.applying(dataProtection, to: &query)
        } else {
            KeychainBackend.applying(to: &query)
        }
        return query
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
