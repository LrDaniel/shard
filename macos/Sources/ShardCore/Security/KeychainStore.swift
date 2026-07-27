import Foundation
import Security

public protocol SecretStoring: Sendable {
    func set(_ secret: String, for reference: String) throws
    func get(_ reference: String) throws -> String?
    func remove(_ reference: String) throws
}

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed with status \(status)."
        case .invalidData:
            return "The stored Keychain value is not valid UTF-8."
        }
    }
}

public final class KeychainStore: SecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.lrdaniel.shard") {
        self.service = service
    }

    public func set(_ secret: String, for reference: String) throws {
        let encoded = Data(secret.utf8)
        let query = baseQuery(reference: reference)
        let attributes = [kSecValueData as String: encoded]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = encoded
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func get(_ reference: String) throws -> String? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    public func remove(_ reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}
