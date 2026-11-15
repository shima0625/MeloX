import Foundation

/// Where a piece of catalog metadata and its audio come from.
///
/// NetEase Cloud Music is the built-in primary source. Every additional
/// service (QQ Music today; Kugou, Bilibili, YouTube Music or LX Music style
/// JavaScript plugins later) is a *third-party source* that plugs into
/// `MusicSourceRegistry` behind `MusicSourceProvider`, so the rest of the app
/// (player, lyrics, queue, search UI) only ever talks to that protocol.
nonisolated enum MusicSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case netease
    case qqMusic

    var id: String { rawValue }

    /// The name shown in pickers and settings.
    var title: String {
        switch self {
        case .netease: L10n.string("ui.source.netease")
        case .qqMusic: L10n.string("ui.source.qq_music")
        }
    }

    var systemImage: String {
        switch self {
        case .netease: "music.note.house"
        case .qqMusic: "music.note.list"
        }
    }

    /// NetEase is served by the built-in API client, everything else has to be
    /// resolved through a registered provider.
    var isThirdParty: Bool { self != .netease }

    /// Third-party sources are only offered while their provider is configured
    /// (for QQ Music that means a stored login session).
    var isRoutable: Bool {
        !isThirdParty || MusicSourceRegistry.shared.isConfigured(self)
    }
}
