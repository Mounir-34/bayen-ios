import Foundation
import Security

/// Persists the access/refresh token pair.
protocol TokenStoring: AnyObject, Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens)
    func clear()
}

/// Keychain-backed store (`kSecClassGenericPassword`, this-device-only, available after first unlock
/// so background uploads can refresh tokens while the phone is locked).
final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private let service: String
    private let account = "auth-tokens"
    private let lock = NSLock()
    private var cache: AuthTokens??

    init(service: String = (Bundle.main.bundleIdentifier ?? "ma.bayen.worker") + ".tokens") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> AuthTokens? {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) else {
            cache = .some(nil)
            return nil
        }
        cache = .some(tokens)
        return tokens
    }

    func save(_ tokens: AuthTokens) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            attributes.forEach { add[$0.key] = $0.value }
            SecItemAdd(add as CFDictionary, nil)
        }
        cache = .some(tokens)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
        cache = .some(nil)
    }
}

/// Used by tests and the mock environment.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }

    func load() -> AuthTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ tokens: AuthTokens) { lock.lock(); defer { lock.unlock() }; self.tokens = tokens }
    func clear() { lock.lock(); defer { lock.unlock() }; tokens = nil }
}
