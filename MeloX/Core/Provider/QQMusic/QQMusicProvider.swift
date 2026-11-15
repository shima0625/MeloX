import Foundation

/// QQ Music as a third-party `MusicSourceProvider`: the endpoints stay in
/// `QQMusicCatalog` / `QQMusicPlaybackClient`, this type maps their JSON onto
/// MeloX's own `Song` / `Album` / `Artist` / `Playlist` models so every
/// existing row, artwork loader and queue keeps working unchanged.
nonisolated final class QQMusicProvider: MusicSourceProvider {
    let kind: MusicSourceKind = .qqMusic
    let capabilities: MusicSourceCapabilities = .fullCatalog

    private let sessionStore: QQMusicSessionStore
    private let api: QQMusicAPIClient
    private let catalog: QQMusicCatalog
    private let playbackClient: QQMusicPlaybackClient

    init(sessionStore: QQMusicSessionStore = .shared) {
        self.sessionStore = sessionStore
        let api = QQMusicAPIClient(sessionStore: sessionStore)
        self.api = api
        catalog = QQMusicCatalog(api: api)
        playbackClient = QQMusicPlaybackClient(api: api)
    }

    var isConfigured: Bool { sessionStore.session.isLoggedIn }

    var session: QQMusicSession { sessionStore.session }

    // MARK: Provider protocol

    func search(
        _ query: String,
        kind: SearchKind,
        limit: Int
    ) async throws -> ProviderSearchResults {
        let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keywords.isEmpty else { return ProviderSearchResults() }
        let pageSize = max(1, min(limit, 50))

        switch kind {
        case .songs:
            let cards = try await catalog.searchSongCards(
                query: keywords,
                page: 1,
                pageSize: pageSize
            )
            return ProviderSearchResults(
                songs: cards.compactMap(Self.song(from:))
            )
        case .albums:
            let data = try await catalog.search(
                query: keywords,
                type: 2,
                page: 1,
                pageSize: pageSize
            )
            return ProviderSearchResults(
                albums: Self.searchItems(data, key: "item_album")
                    .filter { $0["songmid"] == nil && $0["songMid"] == nil }
                    .compactMap(Self.album(from:))
            )
        case .artists:
            let data = try await catalog.search(
                query: keywords,
                type: 1,
                page: 1,
                pageSize: pageSize
            )
            return ProviderSearchResults(
                artists: Self.searchItems(data, key: "singer")
                    .compactMap(Self.artist(from:))
            )
        case .playlists:
            let data = try await catalog.search(
                query: keywords,
                type: 3,
                page: 1,
                pageSize: pageSize
            )
            return ProviderSearchResults(
                playlists: Self.searchItems(data, key: "item_songlist")
                    .compactMap(Self.playlist(from:))
            )
        case .podcasts:
            return ProviderSearchResults()
        }
    }

    func tracks(
        inPlaylist id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage {
        let data = try await catalog.playlistSongs(
            id: id,
            offset: offset,
            limit: limit
        )
        return ProviderTrackPage(
            songs: Self.songCards(data["songlist"], nestedKey: nil)
                .compactMap(Self.song(from:)),
            total: QQMusicJSON.firstInt(
                data,
                ["total_song_num", "songnum", "total"]
            )
        )
    }

    func tracks(
        inAlbum id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage {
        let data = try await catalog.albumSongs(
            id: id,
            offset: offset,
            limit: limit
        )
        return ProviderTrackPage(
            songs: Self.songCards(data["songList"], nestedKey: "songInfo")
                .compactMap(Self.song(from:)),
            total: QQMusicJSON.firstInt(
                data,
                ["totalNum", "total_num", "total"]
            )
        )
    }

    func tracks(
        byArtist id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage {
        let data = try await catalog.artistSongs(
            id: id,
            offset: offset,
            limit: limit
        )
        return ProviderTrackPage(
            songs: Self.songCards(
                data["songList"],
                nestedKey: "songInfo",
                alternativeNestedKey: "trackInfo"
            ).compactMap(Self.song(from:)),
            total: QQMusicJSON.firstInt(
                data,
                ["totalNum", "total_num", "total"]
            )
        )
    }

    func tracks(
        inRanking id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage {
        let data = try await catalog.rankingSongs(
            topID: id,
            offset: offset,
            limit: limit
        )
        let raw = data["song"]
            ?? data["songInfoList"]
            ?? data["songlist"]
            ?? data["songs"]
        return ProviderTrackPage(
            songs: Self.songCards(
                raw,
                nestedKey: "track_info",
                alternativeNestedKey: "songInfo"
            ).compactMap(Self.song(from:)),
            total: QQMusicJSON.firstInt(
                QQMusicJSON.firstDictionary(data, ["info"]) ?? data,
                ["totalNum", "total_num", "total", "songNum"]
            )
        )
    }

    func playbackSource(
        for track: ProviderTrackReference,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        try await playbackClient.playbackSource(
            for: track,
            quality: quality
        )
    }

    // MARK: Account & library (used by `QQMusicStore`)

    func refreshProfile() async throws -> QQMusicSession {
        let login = sessionStore.session
        guard login.isLoggedIn else {
            throw MusicSourceProviderError.loginRequired(.qqMusic)
        }
        let profile = try await catalog.profile(
            uin: login.uin,
            musicKey: login.musicKey
        )
        if let nickname = profile.nickname, !nickname.isEmpty {
            sessionStore.updateProfile(
                nickname: nickname,
                avatarURLString: profile.avatarURLString
            )
        }
        return sessionStore.session
    }

    func userPlaylists() async throws -> [Playlist] {
        let login = sessionStore.session
        guard login.isLoggedIn else {
            throw MusicSourceProviderError.loginRequired(.qqMusic)
        }
        let data = try await catalog.userPlaylists(uin: login.uin)
        let items = QQMusicJSON.objects(data["v_playlist"])
            + QQMusicJSON.objects(data["playlist"])
        return items.compactMap(Self.playlist(from:))
    }

    func rankings(limit: Int = 12) async throws -> [Playlist] {
        let data = try await catalog.rankings()
        var result: [Playlist] = []
        for group in QQMusicJSON.objects(data["group"]) {
            let tops = QQMusicJSON.objects(group["toplist"])
                + QQMusicJSON.objects(group["list"])
            for top in tops where result.count < limit {
                if let playlist = Self.ranking(from: top) {
                    result.append(playlist)
                }
            }
        }
        if result.isEmpty {
            for top in QQMusicJSON.objects(data["toplist"]) where result.count < limit {
                if let playlist = Self.ranking(from: top) {
                    result.append(playlist)
                }
            }
        }
        return result
    }

    func recommendedPlaylists(limit: Int = 12) async throws -> [Playlist] {
        let data = try await catalog.recommendedPlaylists(limit: limit)
        let raw = data["List"]
            ?? data["list"]
            ?? data["songlists"]
        return Self.songCards(raw, nestedKey: "basic")
            .compactMap(Self.playlist(from:))
    }

    // MARK: Mapping helpers

    /// Unwraps the different list shapes of a typed search response.
    private static func searchItems(
        _ data: [String: Any],
        key: String
    ) -> [[String: Any]] {
        let body = QQMusicJSON.dictionary(data["body"]) ?? data
        let direct = QQMusicJSON.objects(body[key])
        if !direct.isEmpty { return direct }
        if let nested = QQMusicJSON.dictionary(body[key]) {
            for inner in ["list", "item", "items"] {
                let objects = QQMusicJSON.objects(nested[inner])
                if !objects.isEmpty { return objects }
            }
        }
        // Last resort: some profiles move the items to a flat array of objects.
        let flattened = QQMusicJSON.deepObjects(body)
        switch key {
        case "item_album":
            return flattened.filter {
                QQMusicJSON.firstString($0, ["albumMid", "albumMID", "albummid"]) != nil
                    && QQMusicJSON.firstString($0, ["songmid", "songMid"]) == nil
            }
        case "singer":
            return flattened.filter {
                QQMusicJSON.firstString($0, ["singerMid", "singerMID", "mid"]) != nil
                    && QQMusicJSON.firstString($0, ["singerName", "name", "title"]) != nil
                    && QQMusicJSON.firstString($0, ["songmid", "albumMid"]) == nil
            }
        default:
            return flattened.filter {
                QQMusicJSON.firstString($0, ["dissid", "dissId", "tid", "disstid"]) != nil
            }
        }
    }

    /// Reads a song list that may wrap each card in `songInfo`, `track_info`
    /// or nothing at all.
    private static func songCards(
        _ raw: Any?,
        nestedKey: String?,
        alternativeNestedKey: String? = nil
    ) -> [[String: Any]] {
        QQMusicJSON.objects(raw).compactMap { card in
            if let nestedKey,
               let nested = QQMusicJSON.dictionary(card[nestedKey]) {
                return nested
            }
            if let alternativeNestedKey,
               let nested = QQMusicJSON.dictionary(card[alternativeNestedKey]) {
                return nested
            }
            if let song = QQMusicJSON.dictionary(card["song"]) {
                return song
            }
            return card
        }
    }

    static func song(from item: [String: Any]) -> Song? {
        let mid = QQMusicJSON.firstString(
            item,
            ["mid", "songmid", "songMid"]
        ) ?? QQMusicJSON.dictionary(item["mid"]).flatMap {
            QQMusicJSON.firstString($0, ["song", "mid"])
        }
        guard let mid, !mid.isEmpty else { return nil }

        let title = QQMusicJSON.firstString(
            item,
            ["name", "title", "songname", "songname_hilight"]
        ) ?? L10n.string("ui.metadata.unknown_song")

        let singers = QQMusicJSON.objects(item["singer"])
            + QQMusicJSON.objects(item["singers"])
        var artists = singers.compactMap { singer -> Artist? in
            guard let name = QQMusicJSON.firstString(
                singer,
                ["name", "title", "singerName"]
            ) else { return nil }
            let singerMid = QQMusicJSON.firstString(
                singer,
                ["mid", "singerMid"]
            )
            let identifier = singerMid.map {
                ProviderTrackReference.syntheticID(for: .qqMusic, mid: $0)
            } ?? ProviderTrackReference.syntheticID(
                for: .qqMusic,
                mid: "artist:\(name)"
            )
            return Artist(id: identifier, name: name)
        }
        if artists.isEmpty {
            artists = [
                Artist(
                    id: ProviderTrackReference.syntheticID(
                        for: .qqMusic,
                        mid: "unknown-artist"
                    ),
                    name: L10n.string("ui.metadata.unknown_artist")
                )
            ]
        }

        let albumObject = QQMusicJSON.dictionary(item["album"])
        let albumMid = QQMusicJSON.firstString(
            albumObject ?? [:],
            ["mid", "albumMid"]
        ) ?? QQMusicJSON.firstString(item, ["albummid", "albumMid"])
        let albumName = QQMusicJSON.firstString(
            albumObject ?? [:],
            ["name", "title", "albumName"]
        ) ?? QQMusicJSON.firstString(item, ["albumname", "albumName"])

        var album: Album?
        if let albumMid, !albumMid.isEmpty {
            let albumID = ProviderTrackReference.syntheticID(
                for: .qqMusic,
                mid: albumMid
            )
            album = Album(
                id: albumID,
                name: albumName ?? L10n.string("ui.metadata.unknown_album"),
                picURL: albumArtworkURLString(mid: albumMid),
                artists: artists
            )
            ProviderResourceRegistry.shared.register(
                ProviderResourceReference(
                    source: .qqMusic,
                    kind: .album,
                    id: albumMid
                ),
                for: albumID
            )
        }

        let mediaMid = QQMusicJSON.dictionary(item["file"]).flatMap {
            QQMusicJSON.firstString($0, ["media_mid", "mediaMid"])
        } ?? QQMusicJSON.firstString(item, ["media_mid", "mediaMid"])

        let numericID = QQMusicJSON.firstInt64(item, ["id", "songid", "songId"])
        let interval = QQMusicJSON.firstInt(
            item,
            ["interval", "duration"]
        ) ?? 0

        return Song(
            id: ProviderTrackReference.syntheticID(
                for: .qqMusic,
                mid: mid
            ),
            name: title,
            artists: artists,
            album: album,
            durationMS: max(interval, 0) * 1_000,
            provider: ProviderTrackReference(
                source: .qqMusic,
                mid: mid,
                mediaMid: mediaMid,
                albumMid: albumMid,
                numericID: numericID
            )
        )
    }

    static func album(from item: [String: Any]) -> Album? {
        let mid = QQMusicJSON.firstString(
            item,
            ["albumMid", "albumMID", "albummid", "mid"]
        )
        let numeric = QQMusicJSON.firstString(
            item,
            ["albumId", "albumID"]
        ) ?? QQMusicJSON.firstInt64(item, ["albumId", "albumID"]).map(String.init)
        guard let identifier = mid ?? numeric, !identifier.isEmpty else {
            return nil
        }
        var artists = (QQMusicJSON.objects(item["singer"])
            + QQMusicJSON.objects(item["singers"])
            + QQMusicJSON.objects(item["singer_list"]))
            .compactMap { singer -> Artist? in
                guard let name = QQMusicJSON.firstString(
                    singer,
                    ["name", "title", "singerName"]
                ) else { return nil }
                let singerMid = QQMusicJSON.firstString(
                    singer,
                    ["mid", "singerMid", "singerMID", "singer_id"]
                )
                return Artist(
                    id: singerMid.map {
                        ProviderTrackReference.syntheticID(
                            for: .qqMusic,
                            mid: $0
                        )
                    } ?? ProviderTrackReference.syntheticID(
                        for: .qqMusic,
                        mid: "artist:\(name)"
                    ),
                    name: name
                )
            }
        // Album search cards carry a plain "周杰伦" string instead of objects.
        if artists.isEmpty,
           let artistText = QQMusicJSON.firstString(
               item,
               ["singer", "author", "singerName"]
           ) {
            artists = artistText
                .components(separatedBy: CharacterSet(charactersIn: "/&、"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { name in
                    Artist(
                        id: ProviderTrackReference.syntheticID(
                            for: .qqMusic,
                            mid: "artist:\(name)"
                        ),
                        name: name
                    )
                }
        }
        let album = Album(
            id: ProviderTrackReference.syntheticID(
                for: .qqMusic,
                mid: identifier
            ),
            name: QQMusicJSON.firstString(
                item,
                ["albumName", "name", "title"]
            ) ?? L10n.string("ui.metadata.unknown_album"),
            picURL: mid.map(albumArtworkURLString(mid:))
                ?? QQMusicJSON.firstString(
                    item,
                    ["picurl", "picUrl", "pic", "cover"]
                ).map(QQMusicJSON.secureURLString),
            artists: artists,
            size: QQMusicJSON.firstInt(
                item,
                ["song_count", "songnum", "songNum", "totalNum"]
            )
        )
        ProviderResourceRegistry.shared.register(
            ProviderResourceReference(
                source: .qqMusic,
                kind: .album,
                id: identifier
            ),
            for: album.id
        )
        return album
    }

    static func artist(from item: [String: Any]) -> Artist? {
        let mid = QQMusicJSON.firstString(
            item,
            ["singerMid", "singerMID", "mid"]
        )
        guard let mid, !mid.isEmpty,
              let name = QQMusicJSON.firstString(
                  item,
                  ["singerName", "name", "title"]
              )
        else { return nil }
        let identifier = ProviderTrackReference.syntheticID(
            for: .qqMusic,
            mid: mid
        )
        ProviderResourceRegistry.shared.register(
            ProviderResourceReference(
                source: .qqMusic,
                kind: .artist,
                id: mid
            ),
            for: identifier
        )
        return Artist(
            id: identifier,
            name: name,
            avatarURL: QQMusicJSON.firstString(
                item,
                ["singerPic", "singerPicUrl", "pic", "picUrl", "avatar"]
            ).map(QQMusicJSON.secureURLString)
                ?? artistArtworkURLString(mid: mid)
        )
    }

    static func playlist(from item: [String: Any]) -> Playlist? {
        let identifier = QQMusicJSON.firstString(
            item,
            ["dissid", "dissId", "disstid", "tid", "playlistId", "id"]
        ) ?? QQMusicJSON.firstInt64(
            item,
            ["dissid", "dissId", "disstid", "tid", "id"]
        ).map(String.init)
        guard let identifier, !identifier.isEmpty else { return nil }
        let playlistID = ProviderTrackReference.syntheticID(
            for: .qqMusic,
            mid: "playlist:\(identifier)"
        )
        ProviderResourceRegistry.shared.register(
            ProviderResourceReference(
                source: .qqMusic,
                kind: .playlist,
                id: identifier
            ),
            for: playlistID
        )
        let creatorName = QQMusicJSON.firstString(
            item,
            ["creatorName", "nickname", "nick"]
        ) ?? QQMusicJSON.dictionary(item["creator"]).flatMap {
            QQMusicJSON.firstString($0, ["nick", "nickname", "name"])
        }
        let cover = QQMusicJSON.firstString(
            item,
            ["imgurl", "imgUrl", "picurl", "picUrl", "logo", "cover"]
        ) ?? QQMusicJSON.dictionary(item["basic"]).flatMap {
            QQMusicJSON.firstString($0, ["picurl", "picUrl", "cover"])
        }
        return Playlist(
            id: playlistID,
            name: QQMusicJSON.firstString(
                item,
                ["dissname", "dirName", "title", "name"]
            ) ?? L10n.string("ui.metadata.unknown_playlist"),
            coverURLString: cover.map(QQMusicJSON.secureURLString),
            playlistDescription: QQMusicJSON.firstString(
                item,
                ["desc", "description"]
            ),
            trackCount: QQMusicJSON.firstInt(
                item,
                ["song_count", "songnum", "songNum", "song_cnt"]
            ) ?? 0,
            playCount: QQMusicJSON.firstInt(
                item,
                ["listen_num", "listennum", "playCnt"]
            ) ?? 0,
            creator: creatorName.map {
                UserSummary(userID: 0, nickname: $0)
            }
        )
    }

    /// Rankings are shown and opened like playlists; the resource registry
    /// remembers that this id has to be fetched through the toplist endpoint.
    static func ranking(from item: [String: Any]) -> Playlist? {
        let identifier = QQMusicJSON.firstString(item, ["topId", "id"])
            ?? QQMusicJSON.firstInt64(item, ["topId", "id"]).map(String.init)
        guard let identifier, !identifier.isEmpty else { return nil }
        let playlistID = ProviderTrackReference.syntheticID(
            for: .qqMusic,
            mid: "ranking:\(identifier)"
        )
        ProviderResourceRegistry.shared.register(
            ProviderResourceReference(
                source: .qqMusic,
                kind: .ranking,
                id: identifier
            ),
            for: playlistID
        )
        let preview = QQMusicJSON.objects(item["song"])
            .prefix(3)
            .compactMap { preview -> String? in
                guard let title = QQMusicJSON.firstString(
                    preview,
                    ["title", "name"]
                ) else { return nil }
                let singer = QQMusicJSON.firstString(
                    preview,
                    ["singerName", "singer_name"]
                )
                return singer.map { "\(title) · \($0)" } ?? title
            }
            .joined(separator: " / ")
        return Playlist(
            id: playlistID,
            name: QQMusicJSON.firstString(
                item,
                ["title", "titleDetail", "name"]
            ) ?? L10n.string("ui.metadata.unknown_playlist"),
            coverURLString: QQMusicJSON.firstString(
                item,
                ["frontPicUrl", "headPicUrl", "cover"]
            ).map(QQMusicJSON.secureURLString),
            playlistDescription: preview.isEmpty ? nil : preview,
            trackCount: QQMusicJSON.firstInt(
                item,
                ["songNum", "songnum", "totalNum"]
            ) ?? 0
        )
    }

    static func albumArtworkURLString(mid: String) -> String {
        "https://y.qq.com/music/photo_new/T002R600x600M000\(mid).jpg"
    }

    static func artistArtworkURLString(mid: String) -> String {
        "https://y.qq.com/music/photo_new/T001R300x300M000\(mid).jpg"
    }
}
