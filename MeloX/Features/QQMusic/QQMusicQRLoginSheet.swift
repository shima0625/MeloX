import SwiftUI
import UIKit

/// Native QR sign-in for QQ Music. The sheet asks the login gateway for a QQ
/// or WeChat QR image, shows it, polls until the phone confirms the scan and
/// stores the finished session through the caller. Nothing here opens
/// `y.qq.com`, so the site cannot hand the user over to the official QQ or
/// WeChat app.
struct QQMusicQRLoginSheet: View {
    var onCookie: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var client = QQMusicQrLoginClient()
    @State private var method: QQMusicQrLoginMethod = .qq
    @State private var attempt = 0
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var sharedFileURL: URL?

    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case succeeded
        case expired
        case rejected
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    methodPicker
                    qrPanel
                    statusLine
                    actions
                    hint
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("ui.qqmusic.qr.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ui.common.close") {
                        dismiss()
                    }
                }
            }
            .task(id: attempt) {
                await runFlow()
            }
        }
    }

    // MARK: Sections

    private var methodPicker: some View {
        Picker("ui.qqmusic.qr.method.section", selection: $method) {
            Text("ui.qqmusic.qr.method.qq")
                .tag(QQMusicQrLoginMethod.qq)
            Text("ui.qqmusic.qr.method.wechat")
                .tag(QQMusicQrLoginMethod.weChat)
        }
        .pickerStyle(.segmented)
        .disabled(isWorking)
        .onChange(of: method) { _, _ in
            attempt += 1
        }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .opacity(phase == .expired || phase == .rejected ? 0.15 : 1)
            } else if case .failed = phase {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
            }
        }
        .frame(width: 240, height: 240)
        .overlay {
            if case .failed = phase {
                EmptyView()
            } else if phase == .expired || phase == .rejected {
                Button {
                    attempt += 1
                } label: {
                    Label("ui.qqmusic.qr.refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.subheadline)
            .foregroundStyle(statusColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.default, value: phase)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let sharedFileURL {
                ShareLink(item: sharedFileURL) {
                    Label("ui.qqmusic.qr.share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                attempt += 1
            } label: {
                Label("ui.qqmusic.qr.refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(phase == .loading)
        }
    }

    private var hint: some View {
        Text("ui.qqmusic.qr.hint")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: State

    private var isWorking: Bool {
        phase == .loading || phase == .scanned
    }

    private var statusText: String {
        switch phase {
        case .loading:
            return L10n.string("ui.qqmusic.qr.status.loading")
        case .waiting:
            return L10n.string(
                method == .qq
                    ? "ui.qqmusic.qr.status.waiting.qq"
                    : "ui.qqmusic.qr.status.waiting.wechat"
            )
        case .scanned:
            return L10n.string(
                method == .qq
                    ? "ui.qqmusic.qr.status.scanned.qq"
                    : "ui.qqmusic.qr.status.scanned.wechat"
            )
        case .succeeded:
            return L10n.string("ui.qqmusic.qr.status.succeeded")
        case .expired:
            return L10n.string("ui.qqmusic.qr.status.expired")
        case .rejected:
            return L10n.string("ui.qqmusic.qr.status.rejected")
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch phase {
        case .scanned, .succeeded:
            return .green
        case .expired, .rejected:
            return .orange
        case .failed:
            return .red
        case .loading, .waiting:
            return .secondary
        }
    }

    // MARK: Flow

    private func runFlow() async {
        phase = .loading
        qrImage = nil
        sharedFileURL = nil
        do {
            let session = try await client.createSession(method: method)
            try Task.checkCancellation()
            qrImage = UIImage(data: session.imageData)
            sharedFileURL = storeTemporaryImage(session)
            phase = .waiting
            while !Task.isCancelled {
                if Date() >= session.expiresAt {
                    phase = .expired
                    return
                }
                let state = try await client.checkSession(session)
                if Task.isCancelled { return }
                switch state {
                case .waiting:
                    if phase != .scanned {
                        phase = .waiting
                    }
                case .scanned:
                    phase = .scanned
                case .expired:
                    phase = .expired
                    return
                case .rejected:
                    phase = .rejected
                    return
                case .authorized(let cookie):
                    phase = .succeeded
                    onCookie(cookie)
                    dismiss()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func storeTemporaryImage(
        _ session: QQMusicQrLoginSession
    ) -> URL? {
        let fileExtension = session.mimeType == "image/png" ? "png" : "jpg"
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "melox-qqmusic-qr-\(session.method.rawValue)-\(stamp).\(fileExtension)"
            )
        do {
            try session.imageData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
