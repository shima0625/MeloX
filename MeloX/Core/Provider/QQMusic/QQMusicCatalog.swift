import Foundation

/// The QQ Music endpoints MeloX uses, each returning the raw `req_0.data`
/// object. Parsing lives in `QQMusicProvider` next to the model mapping.
nonisolated final class QQMusicCatalog: @unchecked Sendable {
    private let api: QQMusicAPIClient

    init(api: QQMusicAPIClient = QQMusicAPIClient()) {
        self.api = api
    }

    // MARK: Search

    /// Typed search (songs / albums / artists / playlists) through the mobile
    /// search gateway, which is the only profile that answers every type.
    func search(
        query: String,
        type: Int,
        page: Int,
        pageSize: Int
    ) async throws -> [String: Any] {
        let start = max(page - 1, 0) * pageSize
        let param: [String: Any] = [
            "query": query,
            "highlight": 0,
            "searchid": "",
            "sub_searchid": 0,
            "search_type": type,
            "nqc_flag": 0,
            "sin": start,
            "ein": start + pageSize,
            "page_num": page,
            "num_per_page": pageSize,
            "cat": 2,
            "grp": 1,
            "remoteplace": "",
            "from": "",
            "multi_zhida": 1,
            "sem": 0,
            "related_data": "",
            "ambi_data": "",
        ]
        return try await api.mobileSearch(param: param)
    }

    /// Song search. The desktop profile returns richer cards, the mobile
    /// profile is the fallback when it answers with an empty shell.
    func searchSongCards(
        query: String,
        page: Int,
        pageSize: Int
    ) async throws -> [[String: Any]] {
        let searchID = "\(Int(Date().timeIntervalSince1970 * 1_000))"
            + "\(Int.random(in: 1_000...9_999))"
        if let desktop = try? await api.request(
            module: "music.search.SearchCgiService",
            method: "DoSearchForQQMusicDesktop",
            param: [
                "query": query,
                "num_per_page": pageSize,
                "page_num": page,
                "searchid": searchID,
                "search_type": 0,
                "grp": true,
            ],
            commType: 11,
            commVersion: 0
        ) {
            let list = QQMusicJSON.objects(
                QQMusicJSON.dictionary(desktop["body"])
                    .flatMap { QQMusicJSON.dictionary($0["song"]) }?["list"]
            )
            if !list.isEmpty {
                return list
            }
        }
        let mobile = try await search(
            query: query,
            type: 0,
            page: page,
            pageSize: pageSize
        )
        let body = QQMusicJSON.dictionary(mobile["body"])
        if let list = QQMusicJSON.dictionary(body?["song"])?["list"],
           !QQMusicJSON.objects(list).isEmpty {
            return QQMusicJSON.objects(list)
        }
        let items = QQMusicJSON.objects(body?["item_song"])
        if !items.isEmpty {
            return items
        }
        return []
    }

    // MARK: Playlists

    func playlistSongs(
        id: String,
        offset: Int,
        limit: Int
    ) async throws -> [String: Any] {
        var param: [String: Any] = [
            "dirid": 0,
            "tag": true,
            "song_begin": offset,
            "song_num": limit,
            "userinfo": true,
            "orderlist": true,
            "onlysonglist": false,
        ]
        if let numeric = Int64(id) {
            param["disstid"] = numeric
        } else {
            param["disstid"] = id
        }
        return try await api.request(
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            param: param
        )
    }

    /// The account's own playlists. `uin` must travel as a JSON string:
    /// sending it as a number makes the gateway answer `code: 10006` with no
    /// playlists at all.
    func userPlaylists(uin: String) async throws -> [String: Any] {
        try await api.request(
            module: "music.musicasset.PlaylistBaseRead",
            method: "GetPlaylistByUin",
            param: ["uin": uin]
        )
    }

    func recommendedPlaylists(limit: Int) async throws -> [String: Any] {
        try await api.request(
            module: "music.playlist.PlaylistSquare",
            method: "GetRecommendFeed",
            param: ["From": 0, "Size": max(1, min(limit, 30))]
        )
    }

    // MARK: Rankings

    func rankings() async throws -> [String: Any] {
        try await api.request(
            module: "music.musicToplist.Toplist",
            method: "GetAll",
            param: [String: Any]()
        )
    }

    func rankingSongs(
        topID: String,
        offset: Int,
        limit: Int
    ) async throws -> [String: Any] {
        var param: [String: Any] = [
            "offset": offset,
            "num": limit,
            "withTags": true,
        ]
        param["topId"] = Int64(topID) ?? 0
        return try await api.request(
            module: "music.musicToplist.Toplist",
            method: "GetDetail",
            param: param
        )
    }

    // MARK: Albums

    func albumSummary(id: String) async throws -> [String: Any] {
        var param: [String: Any] = [:]
        if let numeric = Int64(id) {
            param["albumId"] = numeric
        } else {
            param["albumMId"] = id
        }
        return try await api.request(
            module: "music.musichallAlbum.AlbumInfoServer",
            method: "GetAlbumDetail",
            param: param
        )
    }

    func albumSongs(
        id: String,
        offset: Int,
        limit: Int
    ) async throws -> [String: Any] {
        var param: [String: Any] = [
            "begin": offset,
            "num": limit,
        ]
        if let numeric = Int64(id) {
            param["albumId"] = numeric
        } else {
            param["albumMid"] = id
        }
        return try await api.request(
            module: "music.musichallAlbum.AlbumSongList",
            method: "GetAlbumSongList",
            param: param
        )
    }

    // MARK: Artists

    func artistSongs(
        id: String,
        offset: Int,
        limit: Int
    ) async throws -> [String: Any] {
        try await api.request(
            module: "musichall.song_list_server",
            method: "GetSingerSongList",
            param: [
                "singerMid": id,
                "order": 1,
                "number": limit,
                "begin": offset,
            ]
        )
    }

    // MARK: Account

    func profile(
        uin: String,
        musicKey: String
    ) async throws -> (nickname: String?, avatarURLString: String?) {
        let gtk = QQMusicAPIClient.hash33(musicKey)
        var components = URLComponents(
            string: "https://c6.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg"
        )
        components?.queryItems = [
            URLQueryItem(name: "g_tk", value: String(gtk)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "cid", value: "205360838"),
            URLQueryItem(name: "needNewCode", value: "0"),
            URLQueryItem(name: "loginUin", value: uin),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "userid", value: uin),
            URLQueryItem(name: "reqfrom", value: "1"),
        ]
        guard let url = components?.url else {
            throw MusicSourceProviderError.invalidResponse
        }
        let root = try await api.get(url: url)
        let code = QQMusicJSON.int(root["code"]) ?? 0
        guard code == 0 else {
            let message = QQMusicJSON.firstString(
                root,
                ["message", "msg"]
            ) ?? L10n.format("ui.error.source.code", code)
            throw MusicSourceProviderError.unavailable(message)
        }
        let data = QQMusicJSON.dictionary(root["data"]) ?? root
        let creator = QQMusicJSON.firstDictionary(
            data,
            ["creator", "user", "profile"]
        )
        let nickname = QQMusicJSON.firstString(
            creator ?? [:],
            ["nick", "nickname", "name"]
        ) ?? QQMusicJSON.firstString(
            data,
            ["nick", "nickname", "name"]
        )
        let avatar = QQMusicJSON.firstString(
            creator ?? [:],
            ["headpic", "avatar", "avatarUrl"]
        ) ?? QQMusicJSON.firstString(
            data,
            ["headpic", "avatar", "avatarUrl"]
        )
        return (
            nickname,
            avatar.map(QQMusicJSON.secureURLString)
        )
    }
}
