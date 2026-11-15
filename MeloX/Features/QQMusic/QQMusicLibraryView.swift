import SwiftUI

/// The signed-in QQ Music library: the account's own playlists or the service
/// rankings, both shown with MeloX's regular playlist rows.
struct QQMusicLibraryView: View {
    enum Kind: Hashable {
        case playlists
        case rankings
        case recommended

        var titleKey: String {
            switch self {
            case .playlists: "ui.qqmusic.library.playlists"
            case .rankings: "ui.qqmusic.library.rankings"
            case .recommended: "ui.qqmusic.library.recommended"
            }
        }

        var emptySystemImage: String {
            switch self {
            case .playlists: "music.note.list"
            case .rankings: "chart.bar"
            case .recommended: "sparkles"
            }
        }
    }

    let kind: Kind

    @Environment(QQMusicStore.self) private var store
    @State private var errorMessage: String?

    var body: some View {
        List {
            if store.isLoadingLibrary {
                HStack {
                    Spacer()
                    ProgressView("ui.qqmusic.loading")
                    Spacer()
                }
            }

            ForEach(items) { playlist in
                NavigationLink {
                    QQMusicCollectionView(
                        collection: QQMusicCollection.playlist(playlist)
                            ?? QQMusicCollection(
                                title: playlist.name,
                                subtitle: playlist.creator?.nickname,
                                artworkURL: playlist.artworkURL,
                                target: .playlist(String(playlist.id))
                            )
                    )
                } label: {
                    row(for: playlist)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(kind.titleKey)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if items.isEmpty, !store.isLoadingLibrary {
                ContentUnavailableView(
                    "ui.qqmusic.library.empty",
                    systemImage: kind.emptySystemImage,
                    description: Text(
                        errorMessage
                            ?? L10n.string("ui.qqmusic.library.empty.description")
                    )
                )
            }
        }
        .task {
            await store.loadLibrary(force: true)
            errorMessage = store.libraryError
        }
        .refreshable {
            await store.loadLibrary(force: true)
            errorMessage = store.libraryError
        }
    }

    private var items: [Playlist] {
        switch kind {
        case .playlists: store.myPlaylists
        case .rankings: store.rankings
        case .recommended: store.recommendedPlaylists
        }
    }

    private func row(for playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(url: playlist.artworkURL, cornerRadius: 7)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .lineLimit(1)
                Text(
                    playlist.playlistDescription
                        ?? L10n.format(
                            "ui.common.song_count",
                            playlist.trackCount
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

/// A QQ Music playlist, album, artist or ranking opened as a track list.
struct QQMusicCollectionView: View {
    let collection: QQMusicCollection

    @Environment(QQMusicStore.self) private var store
    @Environment(PlayerStore.self) private var player
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isLoadingMore = false
    @State private var hasMore = false

    var body: some View {
        List {
            Section {
                header
            }

            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    ForEach(songs.indices, id: \.self) { index in
                        let song = songs[index]
                        Button {
                            Task { await player.play(song, in: songs) }
                        } label: {
                            TrackRowView(
                                song: song,
                                index: index + 1,
                                showsArtwork: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if hasMore {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Text("ui.qqmusic.load_more")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoadingMore)
                    }
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkImage(url: collection.artworkURL, cornerRadius: 8)
                .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(collection.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = collection.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button {
                    Task { await playAll() }
                } label: {
                    Label("ui.qqmusic.play_all", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(songs.isEmpty)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await store.songs(
                for: collection,
                offset: 0,
                limit: 100
            )
            songs = page.songs
            if let total = page.total {
                hasMore = songs.count < total
            } else {
                hasMore = page.songs.count >= 100
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.songs(
                for: collection,
                offset: songs.count,
                limit: 100
            )
            let known = Set(songs.map(\.id))
            songs += page.songs.filter { !known.contains($0.id) }
            hasMore = !page.songs.isEmpty
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    private func playAll() async {
        guard !songs.isEmpty else { return }
        await player.playAll(songs)
    }
}
