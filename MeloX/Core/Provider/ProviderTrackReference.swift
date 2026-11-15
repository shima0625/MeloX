import Foundation

/// A track that lives in a third-party catalog.
///
/// `Song.id` is an `Int` because the whole app (queue, favorites, history,
/// persistence) is keyed by it. Third-party tracks get a stable *synthetic*
/// negative identifier derived from the provider's own string id, and keep the
/// provider's identifiers here so playback and lyrics can address them again
/// after the app was restarted.
nonisolated struct ProviderTrackReference: Codable, Hashable, Sendable {
    let source: MusicSourceKind
    /// The provider's track id (QQ Music `songmid`).
    let mid: String
    /// QQ Music's `media_mid`, needed to build a lossless file name.
    let mediaMid: String?
    /// The provider's album id (QQ Music `albummid`).
    let albumMid: String?
    /// The provider's purely numeric track id, used by some write APIs.
    let numericID: Int64?

    init(
        source: MusicSourceKind,
        mid: String,
        mediaMid: String? = nil,
        albumMid: String? = nil,
        numericID: Int64? = nil
    ) {
        self.source = source
        self.mid = mid
        self.mediaMid = mediaMid
        self.albumMid = albumMid
        self.numericID = numericID
    }

    /// Deterministic, always negative identifier so a third-party track can
    /// never collide with a positive NetEase song id, and so the same track
    /// keeps the same id across launches.
    static func syntheticID(for source: MusicSourceKind, mid: String) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(source.rawValue):\(mid)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let bounded = Int(hash % 2_000_000_000)
        return -(bounded + 1)
    }
}

/// The kind of catalog object a synthetic id points at.
nonisolated enum ProviderResourceKind: String, Codable, Hashable, Sendable {
    case album
    case artist
    case playlist
    case ranking
}

/// A non-track catalog object (album, artist, playlist, ranking) in a
/// third-party catalog. `Album`, `Artist` and `Playlist` keep their NetEase
/// shaped models, so their numeric id is resolved back to a provider id here.
nonisolated struct ProviderResourceReference: Codable, Hashable, Sendable {
    let source: MusicSourceKind
    let kind: ProviderResourceKind
    /// The provider's own id: an album/artist mid, a playlist id or a ranking
    /// top id, always kept as a string.
    let id: String
}

/// Remembers which third-party catalog object a synthetic id belongs to.
///
/// The mapping is small and cheap, kept in memory and mirrored into
/// `UserDefaults` so a screen that is restored after relaunch can still be
/// opened. Entries are trimmed oldest-first.
nonisolated final class ProviderResourceRegistry: @unchecked Sendable {
    static let shared = ProviderResourceRegistry()

    private struct Entry: Codable {
        let reference: ProviderResourceReference
        let sequence: UInt64
    }

    private let lock = NSLock()
    private let storageKey = "melox.provider.resources"
    private let capacity = 4_000
    private let defaults: UserDefaults
    private var entries: [String: Entry]
    private var sequence: UInt64

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = Self.load(from: defaults, key: storageKey)
        entries = decoded.entries
        sequence = decoded.sequence
    }

    func register(_ reference: ProviderResourceReference, for integerID: Int) {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        entries[String(integerID)] = Entry(
            reference: reference,
            sequence: sequence
        )
        if entries.count > capacity {
            let overflow = entries.count - capacity
            let oldest = entries
                .sorted { $0.value.sequence < $1.value.sequence }
                .prefix(overflow)
                .map(\.key)
            for key in oldest {
                entries.removeValue(forKey: key)
            }
        }
        persistLocked()
    }

    func reference(
        for integerID: Int,
        kind: ProviderResourceKind? = nil
    ) -> ProviderResourceReference? {
        lock.lock()
        defer { lock.unlock() }
        guard let reference = entries[String(integerID)]?.reference else {
            return nil
        }
        if let kind, reference.kind != kind {
            return nil
        }
        return reference
    }

    func removeAll(for source: MusicSourceKind) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.reference.source != source }
        persistLocked()
    }

    private func persistLocked() {
        let payload = Persisted(entries: entries, sequence: sequence)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private struct Persisted: Codable {
        var entries: [String: Entry]
        var sequence: UInt64
    }

    private static func load(
        from defaults: UserDefaults,
        key: String
    ) -> (entries: [String: Entry], sequence: UInt64) {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Persisted.self, from: data)
        else {
            return ([:], 0)
        }
        return (payload.entries, payload.sequence)
    }
}
