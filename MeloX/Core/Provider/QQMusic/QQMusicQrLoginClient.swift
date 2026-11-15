import Foundation

/// Native QQ Music QR authorization (QQ or WeChat), ported from the Android
/// client. The flow never opens a WebView and never leaves the app: it asks
/// QQ's login gateway for a QR image, polls the scan state and finishes with
/// the `musicId` / `musicKey` pair the rest of the provider already uses.
///
/// Doing it here rather than on `y.qq.com` matters on iOS because the site
/// hands the sign-in over to the official QQ / WeChat app through custom URL
/// schemes, which the in-app browser cannot complete.
nonisolated enum QQMusicQrLoginMethod: String, CaseIterable, Identifiable, Sendable {
    case qq
    case weChat

    var id: String { rawValue }
}

nonisolated enum QQMusicQrLoginEvent: Sendable {
    case waiting
    case scanned
    case connected
    case expired
    case rejected
}

nonisolated struct QQMusicPtuiResult: Sendable {
    var event: QQMusicQrLoginEvent
    var message: String
    var uin: String = ""
    var sigX: String = ""
    var authorizationCode: String = ""
}

nonisolated struct QQMusicQrCredential: Sendable {
    var musicId: String
    var musicKey: String
    var openId: String
    var accessToken: String
    var refreshToken: String
    var unionId: String
    var encryptedUin: String
    var loginType: Int
}

nonisolated enum QQMusicQrLoginState: Sendable {
    case waiting
    case scanned
    case expired
    case rejected
    case authorized(cookie: String)
}

nonisolated enum QQMusicQrLoginError: LocalizedError {
    case requestFailed(String)
    case missingQrToken
    case emptyImage
    case unexpectedResponse(String)
    case serviceRejected(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let detail):
            L10n.format("ui.qqmusic.qr.error.request", detail)
        case .missingQrToken:
            L10n.string("ui.qqmusic.qr.error.missing_token")
        case .emptyImage:
            L10n.string("ui.qqmusic.qr.error.empty_image")
        case .unexpectedResponse(let detail):
            L10n.format("ui.qqmusic.qr.error.response", detail)
        case .serviceRejected(let detail):
            L10n.format("ui.qqmusic.qr.error.rejected", detail)
        }
    }
}

/// A tiny cookie jar for one login attempt. The flow needs the `qrsig` cookie
/// from the QR image request and the `p_skey` cookie from the ticket check, so
/// it keeps them explicitly instead of relying on shared browser storage.
nonisolated final class QQMusicLoginCookieJar: @unchecked Sendable {
    private struct StoredCookie {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expiresAt: Date?
    }

    private let lock = NSLock()
    private var cookies: [String: StoredCookie] = [:]

    /// Names the flow cannot run without; read from the raw header as well,
    /// because a response can carry several `Set-Cookie` headers and only the
    /// first one survives in `allHeaderFields`.
    private static let requiredNames = ["qrsig", "p_skey"]

    func absorb(_ response: URLResponse?, requestURL: URL) {
        guard let http = response as? HTTPURLResponse else { return }
        var rawHeader: String?
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String,
                  name.caseInsensitiveCompare("Set-Cookie") == .orderedSame,
                  let text = value as? String
            else { continue }
            rawHeader = rawHeader.map { $0 + ", " + text } ?? text
        }
        guard let rawHeader, !rawHeader.isEmpty else { return }

        var parsed: [StoredCookie] = []
        let fromFoundation = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": rawHeader],
            for: requestURL
        )
        for cookie in fromFoundation {
            parsed.append(
                StoredCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain.isEmpty
                        ? (requestURL.host ?? "")
                        : cookie.domain,
                    path: cookie.path.isEmpty ? "/" : cookie.path,
                    expiresAt: cookie.expiresDate
                )
            )
        }
        for name in Self.requiredNames
        where !parsed.contains(where: { $0.name == name }) {
            guard let value = Self.rawValue(of: name, in: rawHeader) else {
                continue
            }
            parsed.append(
                StoredCookie(
                    name: name,
                    value: value,
                    domain: requestURL.host ?? "",
                    path: "/",
                    expiresAt: nil
                )
            )
        }
        guard !parsed.isEmpty else { return }

        lock.lock()
        for cookie in parsed {
            cookies["\(cookie.name)|\(cookie.domain)|\(cookie.path)"] = cookie
        }
        lock.unlock()
    }

    func cookieHeader(for url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        lock.lock()
        let now = Date()
        cookies = cookies.filter { _, cookie in
            guard let expiresAt = cookie.expiresAt else { return true }
            return expiresAt > now
        }
        let matching = cookies.values.filter { cookie in
            domainMatches(host, cookie.domain) && path.hasPrefix(cookie.path)
        }
        lock.unlock()
        guard !matching.isEmpty else { return nil }
        return matching
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func value(named name: String, for url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        lock.lock()
        let match = cookies.values.first { cookie in
            cookie.name == name
                && domainMatches(host, cookie.domain)
                && path.hasPrefix(cookie.path)
        }
        lock.unlock()
        return match?.value
    }

    private func domainMatches(_ host: String, _ domain: String) -> Bool {
        let normalized = domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else { return true }
        return host == normalized || host.hasSuffix("." + normalized)
    }

    private static func rawValue(of name: String, in header: String) -> String? {
        let pattern =
            "(?i)(?:^|[;,])\\s*"
            + NSRegularExpression.escapedPattern(for: name)
            + "=([^;,\\s]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: header)
        else { return nil }
        let value = String(header[valueRange])
        return value.isEmpty ? nil : value
    }
}

/// One QR login attempt: the image to show, the token the polling uses and the
/// cookies collected along the way.
nonisolated final class QQMusicQrLoginSession: @unchecked Sendable {
    let method: QQMusicQrLoginMethod
    let imageData: Data
    let mimeType: String
    let token: String
    let expiresAt: Date
    let cookieJar: QQMusicLoginCookieJar

    /// WeChat's long poll answers "scanned" once and then stays quiet, so the
    /// next poll has to repeat the last status.
    var lastWeChatStatus: Int?

    init(
        method: QQMusicQrLoginMethod,
        imageData: Data,
        mimeType: String,
        token: String,
        expiresAt: Date,
        cookieJar: QQMusicLoginCookieJar
    ) {
        self.method = method
        self.imageData = imageData
        self.mimeType = mimeType
        self.token = token
        self.expiresAt = expiresAt
        self.cookieJar = cookieJar
    }
}

/// Blocks every HTTP redirect so the flow can read the `Location` header of
/// QQ's authorize step instead of chasing it to an HTML landing page.
private nonisolated final class QQMusicRedirectBlocker:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated final class QQMusicQrLoginClient: @unchecked Sendable {
    private static let qqLifetime: TimeInterval = 2 * 60
    private static let weChatLifetime: TimeInterval = 5 * 60
    private static let qqQrAppID = "716027609"
    private static let qqMusicOAuthAppID = "100497308"
    private static let qqLoginDaID = "383"
    private static let weChatAppID = "wx48db31d50e334801"
    private static let weChatRedirectURL =
        "https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 MeloX/0.5"

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        session = URLSession(
            configuration: configuration,
            delegate: QQMusicRedirectBlocker(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: Session creation

    func createSession(
        method: QQMusicQrLoginMethod
    ) async throws -> QQMusicQrLoginSession {
        let jar = QQMusicLoginCookieJar()
        switch method {
        case .qq:
            return try await makeQQSession(jar: jar)
        case .weChat:
            return try await makeWeChatSession(jar: jar)
        }
    }

    private func makeQQSession(
        jar: QQMusicLoginCookieJar
    ) async throws -> QQMusicQrLoginSession {
        let micros = Int64(Date().timeIntervalSince1970 * 1_000) * 1_000_000
        var components = URLComponents(
            string: "https://ssl.ptlogin2.qq.com/ptqrshow"
        )
        components?.queryItems = [
            URLQueryItem(name: "appid", value: Self.qqQrAppID),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(micros)),
            URLQueryItem(name: "daid", value: Self.qqLoginDaID),
            URLQueryItem(name: "pt_3rd_aid", value: Self.qqMusicOAuthAppID),
        ]
        guard let url = components?.url else {
            throw QQMusicQrLoginError.unexpectedResponse("ptqrshow")
        }
        let response = try await perform(
            url,
            headers: ["Referer": "https://xui.ptlogin2.qq.com/"],
            jar: jar
        )
        guard (200..<300).contains(response.status) else {
            throw QQMusicQrLoginError.requestFailed("HTTP \(response.status)")
        }
        guard let token = jar.value(named: "qrsig", for: url),
              !token.isEmpty
        else { throw QQMusicQrLoginError.missingQrToken }
        guard !response.data.isEmpty else {
            throw QQMusicQrLoginError.emptyImage
        }
        return QQMusicQrLoginSession(
            method: .qq,
            imageData: response.data,
            mimeType: "image/png",
            token: token,
            expiresAt: Date().addingTimeInterval(Self.qqLifetime),
            cookieJar: jar
        )
    }

    private func makeWeChatSession(
        jar: QQMusicLoginCookieJar
    ) async throws -> QQMusicQrLoginSession {
        var components = URLComponents(
            string: "https://open.weixin.qq.com/connect/qrconnect"
        )
        components?.queryItems = [
            URLQueryItem(name: "appid", value: Self.weChatAppID),
            URLQueryItem(name: "redirect_uri", value: Self.weChatRedirectURL),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "snsapi_login"),
            URLQueryItem(name: "state", value: "STATE"),
        ]
        guard let loginURL = components?.url else {
            throw QQMusicQrLoginError.unexpectedResponse("qrconnect")
        }
        let page = try await perform(loginURL, jar: jar)
        guard (200..<300).contains(page.status) else {
            throw QQMusicQrLoginError.requestFailed("HTTP \(page.status)")
        }
        let uuid = try Self.parseWeChatQRIdentifier(
            String(decoding: page.data, as: UTF8.self)
        )
        guard let imageURL = URL(
            string: "https://open.weixin.qq.com/connect/qrcode/\(uuid)"
        ) else {
            throw QQMusicQrLoginError.unexpectedResponse("qrcode")
        }
        let image = try await perform(
            imageURL,
            headers: ["Referer": loginURL.absoluteString],
            jar: jar
        )
        guard (200..<300).contains(image.status) else {
            throw QQMusicQrLoginError.requestFailed("HTTP \(image.status)")
        }
        guard !image.data.isEmpty else {
            throw QQMusicQrLoginError.emptyImage
        }
        return QQMusicQrLoginSession(
            method: .weChat,
            imageData: image.data,
            mimeType: Self.imageMimeType(for: image.data),
            token: uuid,
            expiresAt: Date().addingTimeInterval(Self.weChatLifetime),
            cookieJar: jar
        )
    }

    // MARK: Polling

    func checkSession(
        _ session: QQMusicQrLoginSession
    ) async throws -> QQMusicQrLoginState {
        if Date() >= session.expiresAt { return .expired }
        let result: QQMusicPtuiResult
        switch session.method {
        case .qq:
            result = try await pollQQ(session)
        case .weChat:
            result = try await pollWeChat(session)
        }
        switch result.event {
        case .waiting:
            return .waiting
        case .scanned:
            return .scanned
        case .expired:
            return .expired
        case .rejected:
            return .rejected
        case .connected:
            let credential: QQMusicQrCredential
            switch session.method {
            case .qq:
                credential = try await authorizeQQ(
                    session,
                    uin: result.uin,
                    sigX: result.sigX
                )
            case .weChat:
                credential = try await exchangeWeChatCode(
                    session,
                    code: result.authorizationCode
                )
            }
            return .authorized(cookie: try Self.cookieHeader(for: credential))
        }
    }

    private func pollQQ(
        _ session: QQMusicQrLoginSession
    ) async throws -> QQMusicPtuiResult {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        var components = URLComponents(
            string: "https://ssl.ptlogin2.qq.com/ptqrlogin"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "u1",
                value: "https://graph.qq.com/oauth2.0/login_jump"
            ),
            URLQueryItem(
                name: "ptqrtoken",
                value: String(
                    QQMusicAPIClient.hash33(session.token, seed: 0)
                )
            ),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(now)"),
            URLQueryItem(name: "js_ver", value: "20102616"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: Self.qqQrAppID),
            URLQueryItem(name: "daid", value: Self.qqLoginDaID),
            URLQueryItem(name: "pt_3rd_aid", value: Self.qqMusicOAuthAppID),
            URLQueryItem(name: "has_onekey", value: "1"),
        ]
        guard let url = components?.url else {
            throw QQMusicQrLoginError.unexpectedResponse("ptqrlogin")
        }
        let response = try await perform(
            url,
            headers: ["Referer": "https://xui.ptlogin2.qq.com/"],
            jar: session.cookieJar
        )
        guard (200..<300).contains(response.status) else {
            throw QQMusicQrLoginError.requestFailed("HTTP \(response.status)")
        }
        return try Self.parsePtuiCallback(
            String(decoding: response.data, as: UTF8.self)
        )
    }

    private func pollWeChat(
        _ session: QQMusicQrLoginSession
    ) async throws -> QQMusicPtuiResult {
        var components = URLComponents(
            string: "https://long.open.weixin.qq.com/connect/l/qrconnect"
        )
        var items = [
            URLQueryItem(name: "uuid", value: session.token),
            URLQueryItem(
                name: "_",
                value: String(Int64(Date().timeIntervalSince1970 * 1_000))
            ),
        ]
        if let last = session.lastWeChatStatus {
            items.append(URLQueryItem(name: "last", value: String(last)))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw QQMusicQrLoginError.unexpectedResponse("qrconnect poll")
        }
        do {
            let response = try await perform(
                url,
                headers: ["Referer": "https://open.weixin.qq.com/"],
                jar: session.cookieJar,
                timeout: 30
            )
            guard (200..<300).contains(response.status) else {
                throw QQMusicQrLoginError.requestFailed(
                    "HTTP \(response.status)"
                )
            }
            let result = try Self.parseWeChatPoll(
                String(decoding: response.data, as: UTF8.self)
            )
            session.lastWeChatStatus = result.event == .scanned ? 404 : nil
            return result
        } catch let error as URLError where error.code == .timedOut {
            // The long poll holds the connection until the user acts.
            return QQMusicPtuiResult(event: .waiting, message: "")
        }
    }

    // MARK: Authorization

    private func authorizeQQ(
        _ session: QQMusicQrLoginSession,
        uin: String,
        sigX: String
    ) async throws -> QQMusicQrCredential {
        var components = URLComponents(
            string: "https://ssl.ptlogin2.graph.qq.com/check_sig"
        )
        components?.queryItems = [
            URLQueryItem(name: "uin", value: uin),
            URLQueryItem(name: "pttype", value: "1"),
            URLQueryItem(name: "service", value: "ptqrlogin"),
            URLQueryItem(name: "nodirect", value: "0"),
            URLQueryItem(name: "ptsigx", value: sigX),
            URLQueryItem(
                name: "s_url",
                value: "https://graph.qq.com/oauth2.0/login_jump"
            ),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "ptredirect", value: "100"),
            URLQueryItem(name: "aid", value: Self.qqQrAppID),
            URLQueryItem(name: "daid", value: Self.qqLoginDaID),
            URLQueryItem(name: "j_later", value: "0"),
            URLQueryItem(name: "low_login_hour", value: "0"),
            URLQueryItem(name: "regmaster", value: "0"),
            URLQueryItem(name: "pt_login_type", value: "3"),
            URLQueryItem(name: "pt_aid", value: "0"),
            URLQueryItem(name: "pt_aaid", value: "16"),
            URLQueryItem(name: "pt_light", value: "0"),
            URLQueryItem(name: "pt_3rd_aid", value: Self.qqMusicOAuthAppID),
        ]
        guard let checkURL = components?.url else {
            throw QQMusicQrLoginError.unexpectedResponse("check_sig")
        }
        let check = try await perform(
            checkURL,
            headers: ["Referer": "https://xui.ptlogin2.qq.com/"],
            jar: session.cookieJar
        )
        guard check.status < 400 else {
            throw QQMusicQrLoginError.requestFailed("HTTP \(check.status)")
        }

        guard let graphURL = URL(string: "https://graph.qq.com/"),
              let pSKey = session.cookieJar.value(
                  named: "p_skey",
                  for: graphURL
              ),
              !pSKey.isEmpty
        else { throw QQMusicQrLoginError.missingQrToken }

        let authorizeURL = URL(string: "https://graph.qq.com/oauth2.0/authorize")
        guard let authorizeURL else {
            throw QQMusicQrLoginError.unexpectedResponse("authorize")
        }
        let form = Self.formBody([
            ("response_type", "code"),
            ("client_id", Self.qqMusicOAuthAppID),
            (
                "redirect_uri",
                "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/"
            ),
            ("scope", "get_user_info,get_app_friends"),
            ("state", "state"),
            ("switch", ""),
            ("from_ptlogin", "1"),
            ("src", "1"),
            ("update_auth", "1"),
            ("openapi", "1010_1030"),
            (
                "g_tk",
                String(QQMusicAPIClient.hash33(pSKey))
            ),
            (
                "auth_time",
                String(Int64(Date().timeIntervalSince1970) * 1_000)
            ),
            ("ui", Self.randomHex(byteCount: 16)),
        ])
        let authorize = try await perform(
            authorizeURL,
            method: "POST",
            headers: ["Referer": "https://graph.qq.com/oauth2.0/login_jump"],
            body: form,
            contentType: "application/x-www-form-urlencoded",
            jar: session.cookieJar
        )
        // The redirect is blocked, so the code sits in the `Location` header;
        // when a proxy answers differently it is in the final URL instead.
        var code = authorize.headers["location"].flatMap(URL.init(string:))
            .flatMap { Self.queryParameter("code", of: $0) }
        if code == nil, let finalURL = authorize.responseURL {
            code = Self.queryParameter("code", of: finalURL)
        }
        guard let code, !code.isEmpty else {
            throw QQMusicQrLoginError.unexpectedResponse("authorize code")
        }
        return try await exchangeQQCode(code)
    }

    private func exchangeQQCode(_ code: String) async throws -> QQMusicQrCredential {
        let payload: [String: Any] = [
            "comm": [
                "ct": 24,
                "cv": 4_747_474,
                "platform": "yqq.json",
                "chid": "0",
                "uin": 0,
                "g_tk": 5381,
                "g_tk_new_20200303": 5381,
                "format": "json",
                "inCharset": "utf-8",
                "outCharset": "utf-8",
                "notice": 0,
                "needNewCode": 1,
                "tmeLoginType": 2,
            ],
            "req_0": [
                "module": "QQConnectLogin.LoginServer",
                "method": "QQLogin",
                "param": ["code": code],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")
        else { throw QQMusicQrLoginError.unexpectedResponse("musicu") }
        let response = try await perform(
            url,
            method: "POST",
            headers: ["Referer": "https://y.qq.com/"],
            body: body,
            contentType: "application/json",
            jar: QQMusicLoginCookieJar()
        )
        let root = Self.jsonObject(response.data)
        let request = root["req_0"] as? [String: Any] ?? [:]
        let resultCode = QQMusicJSON.int(request["code"]) ?? -1
        let rootCode = QQMusicJSON.int(root["code"]) ?? 0
        guard (200..<300).contains(response.status),
              rootCode == 0,
              resultCode == 0
        else {
            throw QQMusicQrLoginError.serviceRejected("\(resultCode)")
        }
        let credential = Self.credential(
            from: request["data"] as? [String: Any] ?? [:]
        )
        guard !credential.musicId.isEmpty, !credential.musicKey.isEmpty else {
            throw QQMusicQrLoginError.serviceRejected("\(resultCode)")
        }
        return credential
    }

    private func exchangeWeChatCode(
        _ session: QQMusicQrLoginSession,
        code: String
    ) async throws -> QQMusicQrCredential {
        guard !code.isEmpty else {
            throw QQMusicQrLoginError.unexpectedResponse("wechat code")
        }
        let payload: [String: Any] = [
            "comm": [
                "tmeAppID": "qqmusic",
                "tmeLoginType": "1",
                "g_tk": 5381,
                "platform": "yqq",
                "ct": 24,
                "cv": 0,
            ],
            "req": [
                "module": "music.login.LoginServer",
                "method": "Login",
                "param": [
                    "strAppid": Self.weChatAppID,
                    "code": code,
                ],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")
        else { throw QQMusicQrLoginError.unexpectedResponse("musicu") }
        let response = try await perform(
            url,
            method: "POST",
            headers: [
                "Accept": "*/*",
                "Referer": Self.weChatRedirectURL,
            ],
            body: body,
            contentType: "application/x-www-form-urlencoded",
            jar: session.cookieJar
        )
        let root = Self.jsonObject(response.data)
        let request = root["req"] as? [String: Any] ?? [:]
        let resultCode = QQMusicJSON.int(request["code"]) ?? -1
        let rootCode = QQMusicJSON.int(root["code"]) ?? 0
        guard (200..<300).contains(response.status),
              rootCode == 0,
              resultCode == 0
        else {
            throw QQMusicQrLoginError.serviceRejected("\(resultCode)")
        }
        let credential = Self.credential(
            from: request["data"] as? [String: Any] ?? [:]
        )
        guard !credential.musicId.isEmpty, !credential.musicKey.isEmpty else {
            throw QQMusicQrLoginError.serviceRejected("\(resultCode)")
        }
        return credential
    }

    // MARK: Transport

    private struct TransportResponse {
        var data: Data
        var status: Int
        var headers: [String: String]
        var responseURL: URL?
    }

    private func perform(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil,
        jar: QQMusicLoginCookieJar,
        timeout: TimeInterval = 25
    ) async throws -> TransportResponse {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/json, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "zh-CN,zh;q=0.9,en;q=0.8",
            forHTTPHeaderField: "Accept-Language"
        )
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let cookie = jar.cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        jar.absorb(response, requestURL: url)
        guard let http = response as? HTTPURLResponse else {
            throw QQMusicQrLoginError.unexpectedResponse("HTTP")
        }
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String
            else { continue }
            headerFields[name.lowercased()] = text
        }
        return TransportResponse(
            data: data,
            status: http.statusCode,
            headers: headerFields,
            responseURL: http.url
        )
    }

    // MARK: Parsing

    static func parsePtuiCallback(_ raw: String) throws -> QQMusicPtuiResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let callback = firstMatch(
            pattern: "ptuiCB\\((.*)\\)",
            in: trimmed,
            options: [.dotMatchesLineSeparators]
        ) else {
            throw QQMusicQrLoginError.unexpectedResponse("ptuiCB")
        }
        let args = allMatches(
            pattern: "'((?:\\\\.|[^'])*)'",
            in: callback
        ).map { value in
            value
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        guard let code = args.first.flatMap(Int.init) else {
            throw QQMusicQrLoginError.unexpectedResponse("ptuiCB code")
        }
        switch code {
        case 0, 405:
            guard args.count > 2,
                  let callbackURL = URL(string: args[2]),
                  let uin = queryParameter("uin", of: callbackURL),
                  let sigX = queryParameter("ptsigx", of: callbackURL),
                  !uin.isEmpty,
                  !sigX.isEmpty
            else {
                throw QQMusicQrLoginError.unexpectedResponse("ptuiCB url")
            }
            return QQMusicPtuiResult(
                event: .connected,
                message: "connected",
                uin: uin,
                sigX: sigX
            )
        case 66, 408:
            return QQMusicPtuiResult(event: .waiting, message: "waiting")
        case 67, 404:
            return QQMusicPtuiResult(event: .scanned, message: "scanned")
        case 65, 402:
            return QQMusicPtuiResult(event: .expired, message: "expired")
        case 68, 403:
            return QQMusicPtuiResult(event: .rejected, message: "rejected")
        default:
            throw QQMusicQrLoginError.unexpectedResponse("ptuiCB \(code)")
        }
    }

    static func parseWeChatQRIdentifier(_ html: String) throws -> String {
        guard let uuid = firstMatch(
            pattern: "/connect/qrcode/([A-Za-z0-9_-]+)",
            in: html
        ), !uuid.isEmpty else {
            throw QQMusicQrLoginError.unexpectedResponse("wechat uuid")
        }
        return uuid
    }

    static func parseWeChatPoll(_ raw: String) throws -> QQMusicPtuiResult {
        guard let statusText = firstMatch(
            pattern: "window\\.wx_errcode\\s*=\\s*(\\d+)",
            in: raw
        ), let status = Int(statusText) else {
            throw QQMusicQrLoginError.unexpectedResponse("wx_errcode")
        }
        switch status {
        case 405:
            guard let code = firstMatch(
                pattern: "window\\.wx_code\\s*=\\s*['\"]([^'\"]+)['\"]",
                in: raw
            ), !code.isEmpty else {
                throw QQMusicQrLoginError.unexpectedResponse("wx_code")
            }
            return QQMusicPtuiResult(
                event: .connected,
                message: "connected",
                authorizationCode: code
            )
        case 408:
            return QQMusicPtuiResult(event: .waiting, message: "waiting")
        case 404:
            return QQMusicPtuiResult(event: .scanned, message: "scanned")
        case 403:
            return QQMusicPtuiResult(event: .rejected, message: "rejected")
        case 402:
            return QQMusicPtuiResult(event: .expired, message: "expired")
        case 500:
            throw QQMusicQrLoginError.serviceRejected("500")
        default:
            throw QQMusicQrLoginError.unexpectedResponse("wx \(status)")
        }
    }

    static func credential(from data: [String: Any]) -> QQMusicQrCredential {
        let musicId = QQMusicJSON.string(data["str_musicid"])
            ?? QQMusicJSON.string(data["musicid"])
            ?? ""
        return QQMusicQrCredential(
            musicId: musicId,
            musicKey: QQMusicJSON.string(data["musickey"]) ?? "",
            openId: QQMusicJSON.string(data["openid"]) ?? "",
            accessToken: QQMusicJSON.string(data["access_token"]) ?? "",
            refreshToken: QQMusicJSON.string(data["refresh_token"]) ?? "",
            unionId: QQMusicJSON.string(data["unionid"]) ?? "",
            encryptedUin: QQMusicJSON.string(data["encryptUin"]) ?? "",
            loginType: QQMusicJSON.int(data["loginType"])
                ?? QQMusicJSON.int(data["login_type"])
                ?? 0
        )
    }

    /// The cookie header the rest of the provider expects: `uin` plus the
    /// music key, with the OAuth values kept for WeChat accounts.
    static func cookieHeader(
        for credential: QQMusicQrCredential
    ) throws -> String {
        var uin = String(credential.musicId.filter { $0.isNumber })
        while uin.hasPrefix("0") {
            uin.removeFirst()
        }
        guard !uin.isEmpty, !credential.musicKey.isEmpty else {
            throw QQMusicQrLoginError.serviceRejected("credential")
        }
        let loginType = credential.loginType != 0
            ? credential.loginType
            : (credential.musicKey.hasPrefix("W_X") ? 1 : 2)
        let fields: [(String, String)] = [
            ("uin", uin),
            ("qqmusic_uin", uin),
            ("qm_keyst", credential.musicKey),
            ("qqmusic_key", credential.musicKey),
            ("music_key", credential.musicKey),
            ("login_type", String(loginType)),
            ("psrf_qqopenid", credential.openId),
            ("psrf_qqaccess_token", credential.accessToken),
            ("psrf_qqrefresh_token", credential.refreshToken),
            ("psrf_qqunionid", credential.unionId),
            ("euin", credential.encryptedUin),
        ]
        return fields
            .filter { _, value in
                !value.isEmpty
                    && !value.contains(";")
                    && !value.contains("\r")
                    && !value.contains("\n")
            }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "; ")
    }

    // MARK: Helpers

    private static func formBody(_ items: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = items.map {
            URLQueryItem(name: $0.0, value: $0.1)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func queryParameter(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    private static func imageMimeType(for data: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if data.count >= 4, Array(data.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
    }

    private static func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func firstMatch(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[valueRange])
        }
    }
}
