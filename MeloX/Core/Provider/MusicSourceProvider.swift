import Foundation

/// What a third-party provider can do. The UI only shows entry points whose
/// capability the provider advertises, so a future source that has no rankings
/// (or no playback yet) simply leaves the flag out.
nonisolated struct MusicSourceCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let search = MusicSourceCapabilities(rawValue: 1 << 0)
    static let playlists = MusicSourceCapabilities(rawValue: 1 << 1)
    static let albums = MusicSourceCapabilities(rawValue: 1 << 2)
    static let artists = MusicSourceCapabilities(rawValue: 1 << 3)
    static let rankings = MusicSourceCapabilities(rawValue: 1 << 4)
    static let playback = MusicSourceCapabilities(rawValue: 1 << 5)
    static let lyrics = MusicSourceCapabilities(rawValue: 1 << 6)
    static let userLibrary = MusicSourceCapabilities(rawValue: 1 << 7)

    static let fullCatalog: MusicSourceCapabilities = [
        .search, .playlists, .albums, .artists, .rankings,
        .playback, .lyrics, .userLibrary,
    ]
}

/// Search results from a third-party source, mapped onto MeloX's own models so
/// the existing rows, artwork loading and navigation keep working unchanged.
nonisolated struct ProviderSearchResults: Sendable {
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
}

/// One page of tracks taken from a provider catalog object.
nonisolated struct ProviderTrackPage: Sendable {
    var songs: [Song]
    var total: Int?

    init(songs: [Song], total: Int? = nil) {
        self.songs = songs
        self.total = total
    }
}

nonisolated enum MusicSourceProviderError: LocalizedError {
    case notConfigured(MusicSourceKind)
    case loginRequired(MusicSourceKind)
    case notFound
    case invalidResponse
    case unavailable(String)
    case playbackDenied(MusicSourceKind, String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let kind):
            L10n.format("ui.error.source.not_configured", kind.title)
        case .loginRequired(let kind):
            L10n.format("ui.error.source.login_required", kind.title)
        case .notFound:
            L10n.string("ui.error.source.not_found")
        case .invalidResponse:
            L10n.string("ui.error.source.invalid_response")
        case .unavailable(let reason):
            reason
        case .playbackDenied(let kind, let detail):
            if let detail, !detail.isEmpty {
                return detail
            }
            return L10n.format("ui.error.source.playback_denied", kind.title)
        }
    }
}

/// The one interface the rest of the app uses to talk to a non-NetEase
/// catalog. A new source is one type conforming to this protocol plus one
/// registration line in `MusicSourceRegistry`.
nonisolated protocol MusicSourceProvider: AnyObject {
    var kind: MusicSourceKind { get }
    var capabilities: MusicSourceCapabilities { get }
    /// `false` while the source has no usable credentials; the UI then offers
    /// the provider's sign-in screen instead of the catalog.
    var isConfigured: Bool { get }

    func search(
        _ query: String,
        kind: SearchKind,
        limit: Int
    ) async throws -> ProviderSearchResults

    func tracks(
        inPlaylist id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage

    func tracks(
        inAlbum id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage

    func tracks(
        byArtist id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage

    func tracks(
        inRanking id: String,
        offset: Int,
        limit: Int
    ) async throws -> ProviderTrackPage

    func playbackSource(
        for track: ProviderTrackReference,
        quality: MusicQuality
    ) async throws -> PlaybackSource
}

/// Holds the registered third-party providers so playback, lyrics and search
/// can reach them without any of them knowing about a concrete service.
nonisolated final class MusicSourceRegistry: @unchecked Sendable {
    static let shared = MusicSourceRegistry()

    private let lock = NSLock()
    private var providers: [MusicSourceKind: any MusicSourceProvider]

    init(providers: [MusicSourceKind: any MusicSourceProvider]? = nil) {
        self.providers = providers ?? Dictionary(
            uniqueKeysWithValues: MusicSourceRegistry.defaultProviders()
                .map { ($0.kind, $0) }
        )
    }

    /// Every third-party source the build knows about. Adding a source starts
    /// here; nothing else in the app needs to change for it to be reachable.
    private static func defaultProviders() -> [any MusicSourceProvider] {
        [QQMusicProvider()]
    }

    func register(_ provider: any MusicSourceProvider) {
        lock.lock()
        providers[provider.kind] = provider
        lock.unlock()
    }

    func provider(for kind: MusicSourceKind) -> (any MusicSourceProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return providers[kind]
    }

    func isConfigured(_ kind: MusicSourceKind) -> Bool {
        guard kind.isThirdParty else { return true }
        return provider(for: kind)?.isConfigured ?? false
    }

    func capabilities(for kind: MusicSourceKind) -> MusicSourceCapabilities {
        provider(for: kind)?.capabilities ?? []
    }

    func playbackSource(
        for track: ProviderTrackReference,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        guard let provider = provider(for: track.source) else {
            throw MusicSourceProviderError.notConfigured(track.source)
        }
        return try await provider.playbackSource(for: track, quality: quality)
    }
}
