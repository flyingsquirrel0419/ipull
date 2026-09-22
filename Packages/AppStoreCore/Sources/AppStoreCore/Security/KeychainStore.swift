import Foundation
#if canImport(Security)
import Security
#endif

/// Abstraction over secret storage so tests can run in-memory.
public protocol SecretStore: Sendable {
    func save(_ data: Data, for key: String) throws
    func load(key: String) throws -> Data?
    func delete(key: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case encodingFailed
    case saveFailed(String)
    #if canImport(Security)
    case unhandledStatus(OSStatus)
    #endif
}

#if canImport(Security)
/// Keychain-backed secret storage.
///
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
/// secrets are device-bound, never migrate via backup/restore, and are
/// available for background download completion after first unlock.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.ipull.app.secrets") {
        self.service = service
    }

    public func save(_ data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unhandledStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw SecretStoreError.unhandledStatus(status)
        }
    }

    public func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecretStoreError.unhandledStatus(status)
        }
        return item as? Data
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unhandledStatus(status)
        }
    }
}
#endif

/// Volatile in-memory store for unit tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }

    public func load(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
