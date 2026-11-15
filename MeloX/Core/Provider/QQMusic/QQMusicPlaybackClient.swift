import Foundation

/// Resolves a QQ Music track into a playable URL through `music.vkey.GetVkey`.
///
/// QQ Music only hands out a URL for the quality the account is allowed to
/// play, so the resolver walks a candidate list from the requested tier down to
/// a always-available fallback and reports the tier that actually produced a
/// URL instead of pretending the requested one worked.
nonisolated final class QQMusicPlaybackClient: @unchecked Sendable {
    private let api: QQMusicAPIClient

    init(api: QQMusicAPIClient = QQMusicAPIClient()) {
        self.api = api
    }

    func playbackSource(
        for track: ProviderTrackReference,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        let login = api.currentSession
        var lastReason: String?
        var businessCodes: [Int] = []

        for candidate in Self.candidates(for: quality) {
            do {
                if let source = try await request(
                    track: track,
                    candidate: candidate
                ) {
                    return source
                }
            } catch let error as VKeyBusinessError {
                businessCodes.append(error.code)
                lastReason = error.localizedDescription
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastReason = error.localizedDescription
            }
        }

        if !login.isLoggedIn {
            throw MusicSourceProviderError.loginRequired(.qqMusic)
        }
        let reason = Self.finalReason(for: businessCodes)
            ?? lastReason
            ?? L10n.format(
                "ui.error.qqmusic.no_source",
                quality.title
            )
        throw MusicSourceProviderError.playbackDenied(.qqMusic, reason)
    }

    private func request(
        track: ProviderTrackReference,
        candidate: QQPlaybackCandidate
    ) async throws -> PlaybackSource? {
        let login = api.currentSession
        let guid = String(Int64.random(in: 1_000_000_000...9_999_999_999))
        let fileName = candidate.fileName(
            songMid: track.mid,
            mediaMid: track.mediaMid
        )
        let body: [String: Any] = [
            "comm": [
                "ct": 11,
                "cv": 14_090_008,
                "v": 14_090_008,
                "qq": login.uin.isEmpty ? "0" : login.uin,
                "authst": login.musicKey,
                "tmeAppID": "qqmusic",
                "format": "json",
            ],
            "req_0": [
                "module": "music.vkey.GetVkey",
                "method": "UrlGetVkey",
                "param": [
                    "uin": login.uin.isEmpty ? "0" : login.uin,
                    "filename": [fileName],
                    "guid": guid,
                    "songmid": [track.mid],
                    "songtype": [0],
                    "ctx": 0,
                ],
            ],
        ]
        let root = try await api.post(
            body: body,
            userAgent: QQMusicAPIClient.androidUserAgent,
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
        guard let data = QQMusicJSON.dictionary(request["data"]) else {
            return nil
        }
        guard let midURL = QQMusicJSON.objects(data["midurlinfo"]).first else {
            return nil
        }
        let resultCode = QQMusicJSON.int(midURL["result"]) ?? 0
        if resultCode != 0 {
            throw VKeyBusinessError(code: resultCode)
        }
        guard var purl = QQMusicJSON.firstString(midURL, ["purl"])
        else { return nil }
        if purl.hasPrefix("http://") || purl.hasPrefix("https://") {
            purl = QQMusicJSON.secureURLString(purl)
        } else {
            let domains = (data["sip"] as? [Any])?
                .compactMap { QQMusicJSON.string($0) } ?? []
            let domain = domains
                .first { !$0.lowercased().hasPrefix("http://ws") }
                ?? domains.first
                ?? "https://isure.stream.qqmusic.qq.com/"
            purl = QQMusicJSON.secureURLString(domain + purl)
        }
        guard let url = URL(string: purl) else {
            throw MusicSourceProviderError.invalidResponse
        }
        return PlaybackSource(
            url: url,
            bitrate: candidate.bitrate,
            format: candidate.fileExtension,
            quality: candidate.actualQuality
        )
    }

    private static func finalReason(for codes: [Int]) -> String? {
        let priority = [104013, 104003, 104004]
        if let code = priority.first(where: { codes.contains($0) }) {
            return VKeyBusinessError(code: code).localizedDescription
        }
        return codes.first.map {
            VKeyBusinessError(code: $0).localizedDescription
        }
    }

    private static func candidates(
        for quality: MusicQuality
    ) -> [QQPlaybackCandidate] {
        switch quality {
        case .standard:
            return [QQPlaybackCandidate("M500", .mp3, .standard, 128_000)]
        case .high:
            return [
                QQPlaybackCandidate("M800", .mp3, .high, 320_000),
                QQPlaybackCandidate("M500", .mp3, .standard, 128_000),
            ]
        case .lossless, .hiResolution:
            return [
                QQPlaybackCandidate("F000", .flac, .lossless),
                QQPlaybackCandidate("M800", .mp3, .high, 320_000),
                QQPlaybackCandidate("M500", .mp3, .standard, 128_000),
            ]
        case .highDefinitionSurround, .immersiveSurround:
            return [
                QQPlaybackCandidate("Q001", .flac, .immersiveSurround),
                QQPlaybackCandidate("Q000", .flac, .immersiveSurround),
                QQPlaybackCandidate("F000", .flac, .lossless),
                QQPlaybackCandidate("M800", .mp3, .high, 320_000),
                QQPlaybackCandidate("M500", .mp3, .standard, 128_000),
            ]
        case .ultraClearMaster:
            return [
                QQPlaybackCandidate("AI00", .flac, .ultraClearMaster),
                QQPlaybackCandidate("F000", .flac, .lossless),
                QQPlaybackCandidate("M800", .mp3, .high, 320_000),
                QQPlaybackCandidate("M500", .mp3, .standard, 128_000),
            ]
        }
    }
}

nonisolated struct QQPlaybackCandidate: Sendable {
    enum FileExtension: String, Sendable {
        case mp3
        case flac
    }

    let prefix: String
    let fileExtension: FileExtension
    let actualQuality: MusicQuality
    let bitrate: Int?

    init(
        _ prefix: String,
        _ fileExtension: FileExtension,
        _ actualQuality: MusicQuality,
        _ bitrate: Int? = nil
    ) {
        self.prefix = prefix
        self.fileExtension = fileExtension
        self.actualQuality = actualQuality
        self.bitrate = bitrate
    }

    var dottedExtension: String { "." + fileExtension.rawValue }

    /// QQ Music builds the file name from the media mid when the track has one
    /// and repeats the song mid when it does not.
    func fileName(songMid: String, mediaMid: String?) -> String {
        if let mediaMid, !mediaMid.isEmpty {
            return prefix + mediaMid + dottedExtension
        }
        return prefix + songMid + songMid + dottedExtension
    }
}

nonisolated struct VKeyBusinessError: LocalizedError {
    let code: Int

    var errorDescription: String? {
        switch code {
        case 104003:
            L10n.string("ui.error.qqmusic.vkey.permission")
        case 104004:
            L10n.string("ui.error.qqmusic.vkey.failed")
        case 104013:
            L10n.string("ui.error.qqmusic.vkey.device")
        default:
            L10n.format("ui.error.qqmusic.vkey.code", code)
        }
    }
}
