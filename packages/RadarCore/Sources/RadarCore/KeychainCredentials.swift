import Foundation
import Security
import LocalAuthentication

public enum APIService: String, CaseIterable, Sendable { case openai, x }

public struct KeychainFailure: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var requiresAuthorization: Bool {
        [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled].contains(status)
    }
    public var errorDescription: String? { "钥匙串操作未完成（\(status)）。请解锁本机钥匙串或检查系统授权后重试。" }
}

/// Credentials are scoped to this app, device-only and never synchronizable.
public struct KeychainCredentials: Sendable {
    private let namespace: String
    public init(namespace: String = "local.resetradar.credentials.v1") { self.namespace = namespace }
    private func query(_ service: APIService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace,
         kSecAttrAccount as String: service.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    public func save(_ secret: String, for service: APIService) throws {
        let cleaned = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 8192,
              !cleaned.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ConnectionFailure(.invalidInput) }
        let attributes: [String: Any] = [kSecValueData as String: Data(cleaned.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query(service) as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let added = SecItemAdd(query(service).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(status: added) }
        } else if updated != errSecSuccess { throw KeychainFailure(status: updated) }
    }
    public func read(_ service: APIService, allowInteraction: Bool = true) throws -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw KeychainFailure(status: errSecDecode) }
        return secret
    }
    public func contains(_ service: APIService) throws -> Bool {
        var q = query(service)
        q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return true
    }
    public func delete(_ service: APIService) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}
