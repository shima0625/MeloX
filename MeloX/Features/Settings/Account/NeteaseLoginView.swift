import SwiftUI
import WebKit

struct NeteaseLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library

    @State private var isLoading = false
    @State private var progress = 0.0

    var body: some View {
        NeteaseLoginWebView(isLoading: $isLoading, progress: $progress)
            .overlay(alignment: .top) {
                if isLoading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            .navigationTitle("ui.settings.account.login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ui.common.cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
            .task {
                await waitForAuthenticatedCookie()
            }
    }

    private func waitForAuthenticatedCookie() async {
        while !Task.isCancelled {
            if let cookieHeader = await NeteaseWebCookieStore.authenticatedCookieHeader() {
                settings.cookie = cookieHeader
                await library.refresh(force: true)
                dismiss()
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}

/// iOS 18-compatible WebKit host. `WebPage`/`WebView` are iOS 26 API, so the
/// login sheet uses `WKWebView` directly and reports its load progress.
struct NeteaseLoginWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var progress: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: NeteaseWebCookieStore.makeConfiguration()
        )
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.observe(webView)
        if let url = URL(string: "https://music.163.com/#") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var parent: NeteaseLoginWebView
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: NeteaseLoginWebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    let value = webView.estimatedProgress
                    Task { @MainActor in
                        self?.parent.progress = value
                    }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    let value = webView.isLoading
                    Task { @MainActor in
                        self?.parent.isLoading = value
                    }
                },
            ]
        }

        func stopObserving() {
            observations.forEach { $0.invalidate() }
            observations = []
        }
    }
}

@MainActor
enum NeteaseWebCookieStore {
    private static let dataStore = WKWebsiteDataStore.default()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        return configuration
    }

    static func authenticatedCookieHeader() async -> String? {
        let cookies = await allCookies().filter(isUsableNeteaseCookie)
        guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else {
            return nil
        }

        let values = cookies.reduce(into: [String: String]()) { result, cookie in
            result[cookie.name] = cookie.value
        }
        return values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }

    static func clear() async {
        for cookie in await allCookies() where isNeteaseCookie(cookie) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func isUsableNeteaseCookie(_ cookie: HTTPCookie) -> Bool {
        isNeteaseCookie(cookie) && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    private static func isNeteaseCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == "163.com" || domain.hasSuffix(".163.com")
    }
}
