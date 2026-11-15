import Foundation
import Security

/// A QQ Music login: the cookie header used for every request plus the two
/// values the API actually needs (`uin` and the music key).
nonisolated struct QQMusicSession: Codable, Hashable, Sendable {
    var cookie: String
    var uin: String
    var musicKey: String
    private(set) var nickname: String
    private(set) var avatarURLString: String?
    var loginType: Int
    var savedAt: Date

    var isLoggedIn: Bool {
        !uin.isEmpty && !musicKey.isEmpty
    }

    var displayName: String {
        nickname.isEmpty ? uin : nickname
    }

    var avatarURL: URL? {
        guard var source = avatarURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !source.isEmpty
        else { return nil }
        if source.hasPrefix("//") {
            source = "https:\(source)"
        } else if source.hasPrefix("http://") {
            source = "https://" + source.dropFirst("http://".count)
        }
        return URL(string: source)
    }

    init(
        cookie: String,
        uin: String = "",
        musicKey: String = "",
        nickname: String = "",
        avatarURLString: String? = nil,
        loginType: Int = 0,
        savedAt: Date = Date()
    ) {
        self.cookie = cookie
        self.uin = uin
        self.musicKey = musicKey
        self.nickname = nickname
        self.avatarURLString = avatarURLString
        self.loginType = loginType
        self.savedAt = savedAt
    }

    static let signedOut = QQMusicSession(cookie: "")

    mutating func applyProfile(nickname: String, avatarURLString: String?) {
        self.nickname = nickname
        if let avatarURLString, !avatarURLString.isEmpty {
            self.avatarURLString = avatarURLString
        }
    }

    /// Builds a session from a pasted or harvested cookie header. Returns
    /// `nil` when the cookie does not carry a usable login.
    static func parsed(fromCookie cookie: String) -> QQMusicSession? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let values = cookieValues(trimmed)
        let loginType = Int(values["login_type"] ?? "") ?? 0
        let rawUin: String
        if !(values["qqmusic_uin"] ?? "").isEmpty {
            rawUin = values["qqmusic_uin"] ?? ""
        } else if loginType == 2, let wechat = values["wxuin"] {
            rawUin = wechat
        } else if let uin = values["uin"] {
            rawUin = uin
        } else {
            rawUin = values["wxuin"] ?? ""
        }
        let uin = rawUin.filter(\.isNumber)
        let musicKey = (values["qm_keyst"] ?? "").isEmpty
            ? (values["qqmusic_key"] ?? values["music_key"] ?? "")
            : (values["qm_keyst"] ?? "")
        guard !uin.isEmpty, !musicKey.isEmpty else { return nil }
        return QQMusicSession(
            cookie: trimmed,
            uin: uin,
            musicKey: musicKey,
            loginType: loginType
        )
    }

    static func cookieValues(_ cookie: String) -> [String: String] {
        var values: [String: String] = [:]
        for entry in cookie.split(separator: ";") {
            let part = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = part.firstIndex(of: "="),
                  separator != part.startIndex
            else { continue }
            let name = String(part[part.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(part[part.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                values[name] = value
            }
        }
        return values
    }
}

/// Persists the QQ Music session. The cookie is kept in the keychain when the
/// keychain is reachable and in `UserDefaults` otherwise (unsigned installs can
/// refuse keychain writes), the profile text stays in `UserDefaults`.
nonisolated final class QQMusicSessionStore: @unchecked Sendable {
    static let shared = QQMusicSessionStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let defaultsKey = "melox.qqmusic.session"
    private let keychainService = "moye.MeloX.qqmusic"
    private let keychainAccount = "session"
    private var cached: QQMusicSession?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var session: QQMusicSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = loadLocked() ?? .signedOut
        cached = loaded
        return loaded
    }

    var isLoggedIn: Bool { session.isLoggedIn }

    @discardableResult
    func save(_ session: QQMusicSession) -> QQMusicSession {
        lock.lock()
        defer { lock.unlock() }
        var normalized = session
        normalized.savedAt = Date()
        cached = normalized
        persistLocked(normalized)
        return normalized
    }

    func updateProfile(nickname: String, avatarURLString: String?) {
        lock.lock()
        defer { lock.unlock() }
        var current = cached ?? loadLocked() ?? .signedOut
        guard current.isLoggedIn else { return }
        current.applyProfile(
            nickname: nickname,
            avatarURLString: avatarURLString
        )
        cached = current
        persistLocked(current)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = .signedOut
        defaults.removeObject(forKey: defaultsKey)
        QQMusicSessionStore.deleteKeychainItem(
            service: keychainService,
            account: keychainAccount
        )
    }

    private func persistLocked(_ session: QQMusicSession) {
        guard let payload = try? JSONEncoder().encode(session) else { return }
        let storedInKeychain = QQMusicSessionStore.writeKeychainItem(
            payload,
            service: keychainService,
            account: keychainAccount
        )
        if storedInKeychain {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(payload, forKey: defaultsKey)
        }
    }

    private func loadLocked() -> QQMusicSession? {
        if let data = QQMusicSessionStore.readKeychainItem(
            service: keychainService,
            account: keychainAccount
        ), let session = try? JSONDecoder().decode(QQMusicSession.self, from: data) {
            return session
        }
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(QQMusicSession.self, from: data)
    }

    private static func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func writeKeychainItem(
        _ data: Data,
        service: String,
        account: String
    ) -> Bool {
        var query = baseQuery(service: service, account: account)
        let status = SecItemCopyMatching(
            query as CFDictionary,
            nil
        )
        if status == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            return updateStatus == errSecSuccess
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func readKeychainItem(
        service: String,
        account: String
    ) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteKeychainItem(service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        _ = SecItemDelete(query as CFDictionary)
    }
}
