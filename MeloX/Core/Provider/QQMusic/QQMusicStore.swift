import Foundation

/// A QQ Music catalog object that can be opened as a track list. The synthetic
/// id of the underlying `Playlist` / `Album` / `Artist` is resolved back to the
/// provider's own id through `ProviderResourceRegistry`.
nonisolated struct QQMusicCollection: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case playlist(String)
        case album(String)
        case artist(String)
        case ranking(String)
    }

    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let target: Target

    var id: String {
        switch target {
        case .playlist(let id): "playlist:\(id)"
        case .album(let id): "album:\(id)"
        case .artist(let id): "artist:\(id)"
        case .ranking(let id): "ranking:\(id)"
        }
    }

    static func playlist(_ playlist: Playlist) -> QQMusicCollection? {
        guard let reference = ProviderResourceRegistry.shared.reference(
            for: playlist.id
        ) else { return nil }
        let target: Target
        switch reference.kind {
        case .playlist: target = .playlist(reference.id)
        case .ranking: target = .ranking(reference.id)
        case .album: target = .album(reference.id)
        case .artist: target = .artist(reference.id)
        }
        return QQMusicCollection(
            title: playlist.name,
            subtitle: playlist.creator?.nickname,
            artworkURL: playlist.artworkURL,
            target: target
        )
    }

    static func ranking(_ playlist: Playlist) -> QQMusicCollection? {
        guard let reference = ProviderResourceRegistry.shared.reference(
            for: playlist.id,
            kind: .ranking
        ) else { return nil }
        return QQMusicCollection(
            title: playlist.name,
            subtitle: playlist.playlistDescription,
            artworkURL: playlist.artworkURL,
            target: .ranking(reference.id)
        )
    }

    static func album(_ album: Album) -> QQMusicCollection? {
        guard let reference = ProviderResourceRegistry.shared.reference(
            for: album.id,
            kind: .album
        ) else { return nil }
        return QQMusicCollection(
            title: album.name,
            subtitle: album.artistText,
            artworkURL: album.artworkURL,
            target: .album(reference.id)
        )
    }

    static func artist(_ artist: Artist) -> QQMusicCollection? {
        guard let reference = ProviderResourceRegistry.shared.reference(
            for: artist.id,
            kind: .artist
        ) else { return nil }
        return QQMusicCollection(
            title: artist.name,
            subtitle: nil,
            artworkURL: artist.artworkURL,
            target: .artist(reference.id)
        )
    }
}

nonisolated enum QQMusicStoreError: LocalizedError {
    case invalidCookie
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .invalidCookie:
            L10n.string("ui.qqmusic.error.invalid_cookie")
        case .notSignedIn:
            L10n.string("ui.qqmusic.error.not_signed_in")
        }
    }
}

/// Main-actor façade over the QQ Music provider: sign-in state, the user's
/// library and the track lists the QQ Music screens show.
@MainActor
@Observable
final class QQMusicStore {
    @ObservationIgnored
    private let provider: QQMusicProvider

    private(set) var session: QQMusicSession
    private(set) var myPlaylists: [Playlist] = []
    private(set) var rankings: [Playlist] = []
    private(set) var recommendedPlaylists: [Playlist] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryError: String?
    private(set) var isSigningIn = false

    init(provider: QQMusicProvider = QQMusicProvider()) {
        self.provider = provider
        session = provider.session
    }

    var isSignedIn: Bool { session.isLoggedIn }
    var displayName: String { session.displayName }
    var avatarURL: URL? { session.avatarURL }
    var uin: String { session.uin }

    var capabilities: MusicSourceCapabilities { provider.capabilities }

    func refreshSession() {
        session = provider.session
    }

    // MARK: Sign-in

    /// Stores a cookie header harvested from the in-app browser or pasted by
    /// the user. Throws when the cookie carries no QQ Music login.
    func signIn(cookie: String) throws {
        guard let parsed = QQMusicSession.parsed(fromCookie: cookie) else {
            throw QQMusicStoreError.invalidCookie
        }
        session = QQMusicSessionStore.shared.save(parsed)
        ProviderResourceRegistry.shared.removeAll(for: .qqMusic)
        clearLibrary()
        Task { await loadProfile() }
    }

    func signOut() {
        QQMusicSessionStore.shared.clear()
        ProviderResourceRegistry.shared.removeAll(for: .qqMusic)
        session = .signedOut
        clearLibrary()
    }

    private func clearLibrary() {
        myPlaylists = []
        rankings = []
        recommendedPlaylists = []
        libraryError = nil
    }

    func loadProfile() async {
        guard session.isLoggedIn else { return }
        do {
            session = try await provider.refreshProfile()
        } catch is CancellationError {
            return
        } catch {
            // A rejected cookie keeps the session but reports the problem when
            // the user opens the library.
            libraryError = error.localizedDescription
        }
    }

    // MARK: Library

    func loadLibrary(force: Bool = false) async {
        refreshSession()
        guard session.isLoggedIn else { return }
        guard force || myPlaylists.isEmpty || rankings.isEmpty else {
            return
        }
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }

        do {
            async let userPlaylists = provider.userPlaylists()
            async let rankingList = provider.rankings()
            let (playlists, rankingsResult) = try await (
                userPlaylists,
                rankingList
            )
            myPlaylists = playlists
            rankings = rankingsResult
        } catch is CancellationError {
            return
        } catch {
            libraryError = error.localizedDescription
        }

        if recommendedPlaylists.isEmpty {
            recommendedPlaylists =
                (try? await provider.recommendedPlaylists()) ?? []
        }
    }

    // MARK: Search

    func search(
        _ query: String,
        kind: SearchKind,
        limit: Int = 30
    ) async throws -> ProviderSearchResults {
        try await provider.search(query, kind: kind, limit: limit)
    }

    // MARK: Track lists

    func songs(
        for collection: QQMusicCollection,
        offset: Int = 0,
        limit: Int = 100
    ) async throws -> ProviderTrackPage {
        switch collection.target {
        case .playlist(let id):
            return try await provider.tracks(
                inPlaylist: id,
                offset: offset,
                limit: limit
            )
        case .album(let id):
            return try await provider.tracks(
                inAlbum: id,
                offset: offset,
                limit: limit
            )
        case .artist(let id):
            return try await provider.tracks(
                byArtist: id,
                offset: offset,
                limit: limit
            )
        case .ranking(let id):
            return try await provider.tracks(
                inRanking: id,
                offset: offset,
                limit: limit
            )
        }
    }
}
