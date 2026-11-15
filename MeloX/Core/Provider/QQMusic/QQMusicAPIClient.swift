import Foundation

/// `JSONSerialization` hands back loosely typed values, and QQ Music answers
/// with inconsistent shapes (numbers as strings, objects nested differently
/// between the mobile and desktop endpoints). These helpers read all of them.
nonisolated enum QQMusicJSON {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as NSString:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        int64(value).map { Int($0) }
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as NSNumber:
            return value.int64Value
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as Double:
            return Int64(value)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Int64(trimmed) { return parsed }
            return Double(trimmed).map { Int64($0) }
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []
    }

    static func firstString(
        _ dictionary: [String: Any],
        _ keys: [String]
    ) -> String? {
        for key in keys {
            if let value = string(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    static func firstInt(
        _ dictionary: [String: Any],
        _ keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = int(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    static func firstInt64(
        _ dictionary: [String: Any],
        _ keys: [String]
    ) -> Int64? {
        for key in keys {
            if let value = int64(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    static func firstDictionary(
        _ dictionary: [String: Any],
        _ keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = self.dictionary(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    /// Every object found anywhere in the tree, parents before children. Used
    /// to read search responses whose item lists move between releases.
    static func deepObjects(_ value: Any?, depth: Int = 0) -> [[String: Any]] {
        guard depth < 12 else { return [] }
        switch value {
        case let dictionary as [String: Any]:
            var result: [[String: Any]] = [dictionary]
            for nested in dictionary.values {
                result.append(contentsOf: deepObjects(nested, depth: depth + 1))
            }
            return result
        case let array as [Any]:
            return array.flatMap { deepObjects($0, depth: depth + 1) }
        default:
            return []
        }
    }

    static func secureURLString(_ value: String) -> String {
        guard value.hasPrefix("http://") else { return value }
        return "https://" + value.dropFirst("http://".count)
    }

    /// Several legacy `c.y.qq.com` endpoints answer with JSONP.
    static func payloadString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first < last
        else { return nil }
        return String(trimmed[first...last])
    }
}

/// Low level QQ Music transport: `musicu.fcg` requests, the profile endpoint
/// and the JSONP helpers. Everything is built from the stored session, so
/// signing out immediately stops every authenticated call.
nonisolated final class QQMusicAPIClient: @unchecked Sendable {
    static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let androidUserAgent = "QQMusic 14090008(android 15)"

    private let session: URLSession
    private let sessionStore: QQMusicSessionStore

    init(
        session: URLSession = .shared,
        sessionStore: QQMusicSessionStore = .shared
    ) {
        self.session = session
        self.sessionStore = sessionStore
    }

    var currentSession: QQMusicSession { sessionStore.session }

    /// QQ Music's `hash33`, used for `g_tk` and login tokens.
    static func hash33(_ value: String, seed: UInt64 = 5381) -> UInt64 {
        var hash = seed
        for byte in value.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
            hash &= 0xFFFF_FFFF
        }
        return hash & 0x7FFF_FFFF
    }

    func request(
        module: String,
        method: String,
        param: [String: Any],
        commType: Int = 24,
        commVersion: Int64 = 4_747_474,
        userAgent: String = QQMusicAPIClient.desktopUserAgent
    ) async throws -> [String: Any] {
        let login = currentSession
        let gtk = QQMusicAPIClient.hash33(login.musicKey)
        let comm: [String: Any] = [
            "ct": commType,
            "cv": commVersion,
            "platform": "yqq.json",
            "chid": "0",
            "uin": Int64(login.uin) ?? 0,
            "g_tk": Int(gtk),
            "g_tk_new_20200303": Int(gtk),
            "format": "json",
            "inCharset": "utf-8",
            "outCharset": "utf-8",
            "notice": 0,
            "need_new_code": 1,
        ]
        let body: [String: Any] = [
            "comm": comm,
            "req_0": [
                "module": module,
                "method": method,
                "param": param,
            ],
        ]
        let root = try await post(
            body: body,
            userAgent: userAgent,
            referer: "https://y.qq.com/"
        )
        guard let request = QQMusicJSON.dictionary(root["req_0"]) else {
            throw MusicSourceProviderError.invalidResponse
        }
        let code = QQMusicJSON.int(request["code"]) ?? 0
        guard code == 0 else {
            let message = QQMusicJSON.firstString(
                request,
                ["message", "msg"]
            ) ?? L10n.format("ui.error.source.code", code)
            throw MusicSourceProviderError.unavailable(message)
        }
        return QQMusicJSON.dictionary(request["data"]) ?? [:]
    }

    func post(
        body: [String: Any],
        userAgent: String,
        referer: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")
        else { throw MusicSourceProviderError.invalidResponse }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let login = currentSession
        if !login.cookie.isEmpty {
            request.setValue(login.cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw MusicSourceProviderError.invalidResponse
        }
        return root
    }

    /// The mobile search gateway. Typed search (albums, artists, playlists)
    /// and the song-search fallback only answer this shape: a top-level result
    /// key instead of `req_0`, `ct 11` / `v 20080508` instead of the desktop
    /// comm block, and the mobile client as user agent.
    func mobileSearch(param: [String: Any]) async throws -> [String: Any] {
        let key = "music.search.SearchCgiService.DoSearchForQQMusicMobile"
        let body: [String: Any] = [
            "comm": [
                "ct": "11",
                "v": "20080508",
                "tmeLoginType": "0",
                "tmeLoginMethod": "0",
            ],
            key: [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicMobile",
                "param": param,
            ],
        ]
        guard let url = URL(string: "https://u6.y.qq.com/cgi-bin/musicu.fcg")
        else { throw MusicSourceProviderError.invalidResponse }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(
            "QQMusic 20080508(android)",
            forHTTPHeaderField: "User-Agent"
        )
        let login = currentSession
        if !login.cookie.isEmpty {
            request.setValue(login.cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw MusicSourceProviderError.invalidResponse
        }
        let rootCode = QQMusicJSON.int(root["code"]) ?? 0
        guard rootCode == 0 else {
            throw MusicSourceProviderError.unavailable(
                L10n.format("ui.error.source.code", rootCode)
            )
        }
        guard let result = QQMusicJSON.dictionary(root[key]) else {
            throw MusicSourceProviderError.invalidResponse
        }
        let code = QQMusicJSON.int(result["code"]) ?? 0
        guard code == 0 else {
            let message = QQMusicJSON.firstString(
                result,
                ["message", "msg"]
            ) ?? L10n.format("ui.error.source.code", code)
            throw MusicSourceProviderError.unavailable(message)
        }
        return QQMusicJSON.dictionary(result["data"]) ?? [:]
    }

    func get(
        url: URL,
        userAgent: String = QQMusicAPIClient.desktopUserAgent,
        referer: String = "https://y.qq.com/"
    ) async throws -> [String: Any] {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let login = currentSession
        if !login.cookie.isEmpty {
            request.setValue(login.cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8),
              let payload = QQMusicJSON.payloadString(from: text),
              let object = try JSONSerialization.jsonObject(
                  with: Data(payload.utf8)
              ) as? [String: Any]
        else {
            throw MusicSourceProviderError.invalidResponse
        }
        return object
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MusicSourceProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MusicSourceProviderError.unavailable(
                L10n.format("ui.error.source.http", http.statusCode)
            )
        }
    }
}
