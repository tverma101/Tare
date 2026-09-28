import Foundation
import Security

/// Chooses which Keychain implementation Tare's secrets live in.
///
/// `SecItem` targets the file-based login Keychain by default, and on that
/// implementation `kSecAttrAccessible` is not honoured. So
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` silently does nothing, and the
/// item remains eligible for Keychain backup and iCloud sync.
///
/// The data-protection Keychain does enforce that attribute, but it is only
/// reachable by an app carrying a `keychain-access-groups` entitlement naming
/// the signing team. Two things make that awkward to rely on:
///
///   - `$(AppIdentifierPrefix)` is only substituted when a provisioning profile
///     is embedded, so a template entitlements file signs as a literal,
///     non-matching group unless the builder generates one with their own team
///     identifier.
///   - A group that does not match the app's real application identifier makes
///     every Keychain call fail with `errSecMissingEntitlement`, which would
///     stop the user saving an API key at all.
///
/// So the backend is probed with a throwaway write and the legacy implementation
/// is used whenever the entitlement is absent. A builder who does supply a valid
/// entitlement gets the data-protection Keychain and an automatic migration of
/// any secret written earlier; everyone else degrades without noticing.
///
/// Known boundary: on a build without the entitlement, Tare's API keys are stored
/// in the file-based login Keychain and can therefore be included in Keychain
/// backup or iCloud Keychain sync. Nothing else about their handling changes.
enum KeychainBackend {
    private static let lock = NSLock()
    private static var resolved: Bool?

    /// True when secrets can be stored in the data-protection Keychain.
    static var usesDataProtection: Bool {
        lock.lock()
        defer { lock.unlock() }

        if let resolved { return resolved }
        let supported = Self.probe()
        resolved = supported
        return supported
    }

    /// Detects the entitlement by actually writing a throwaway item.
    ///
    /// A read is not enough: with no entitlement a data-protection
    /// `SecItemCopyMatching` still reports "not found" rather than
    /// `errSecMissingEntitlement`, so only an add reveals the missing
    /// entitlement. The probe item is deleted immediately and never holds a
    /// secret.
    private static func probe() -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tejas.Tare.keychain-backend-probe",
            kSecAttrAccount as String: "probe"
        ]

        var addQuery = identity
        addQuery[kSecValueData as String] = Data([0x00])
        addQuery[kSecAttrAccessible as String] = secretAccessibility
        addQuery[kSecUseDataProtectionKeychain as String] = true

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            // Must carry the same keychain selector as the add, or it targets a
            // different keychain and leaves the probe item behind.
            var deleteQuery = identity
            deleteQuery[kSecUseDataProtectionKeychain as String] = true
            SecItemDelete(deleteQuery as CFDictionary)
            return true
        default:
            return false
        }
    }

    /// Adds the data-protection selector to a query when it is usable.
    static func applying(to query: inout [String: Any]) {
        guard usesDataProtection else { return }
        query[kSecUseDataProtectionKeychain as String] = true
    }

    /// Builds a query for a specific implementation, which the migration path
    /// needs in order to read from one and write to the other.
    static func applying(_ dataProtection: Bool, to query: inout [String: Any]) {
        guard dataProtection else { return }
        query[kSecUseDataProtectionKeychain as String] = true
    }

    /// `kSecAttrAccessible` only has an effect on the data-protection Keychain,
    /// but it is harmless on the legacy one, so it is always supplied.
    static let secretAccessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
}
