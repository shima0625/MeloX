import SwiftUI
import WebKit

/// Loads the desktop QQ Music site in an in-app browser so the user can sign in
/// with the page's own QR code or password form. The mobile site is avoided on
/// purpose: it turns the sign-in entry point into an `mqq://` / `weixin://`
/// hand-off, which cannot finish inside the app. Once the login cookies appear,
/// the cookie header is handed back and stored as the session.
struct QQMusicWebLoginView: UIViewRepresentable {
    var onCookie: (String) -> Void

    /// Bumped by the sheet's toolbar button to reload the sign-in page.
    var reloadToken: Int = 0

    static let homeURL = URL(string: "https://y.qq.com/")

    /// A desktop Safari user agent keeps `y.qq.com` on the web sign-in flow
    /// instead of redirecting to the mobile page and the official app.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.0 Safari/605.1.15"

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.desktopUserAgent
        context.coordinator.reloadToken = reloadToken
        if let url = Self.homeURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.reloadToken != reloadToken else { return }
        context.coordinator.reloadToken = reloadToken
        guard let url = Self.homeURL else { return }
        uiView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookie: onCookie)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCookie: (String) -> Void
        private var hasReported = false
        var reloadToken = 0

        init(onCookie: @escaping (String) -> Void) {
            self.onCookie = onCookie
        }

        /// Everything except plain web pages is refused: the QQ and WeChat
        /// sign-in hand-offs (`mqq://`, `wtloginmqq://`, `weixin://`,
        /// `qqmusic://`), the App Store (`itms-apps://`) and any other app
        /// scheme would leave the app without a session.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// `target="_blank"` windows (the site opens the sign-in dialog this
        /// way) are loaded in the same web view so the dialog cannot vanish.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url
            else { return nil }
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            harvestCookies(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            didCommit navigation: WKNavigation!
        ) {
            harvestCookies(from: webView)
        }

        private func harvestCookies(from webView: WKWebView) {
            guard !hasReported else { return }
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies { [weak self] cookies in
                    guard let self, !self.hasReported else { return }
                    let loginCookies = cookies.filter {
                        $0.domain.contains("qq.com")
                    }
                    guard !loginCookies.isEmpty else { return }
                    let header = loginCookies
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    guard QQMusicSession.parsed(fromCookie: header) != nil
                    else { return }
                    self.hasReported = true
                    DispatchQueue.main.async {
                        self.onCookie(header)
                    }
                }
        }
    }
}

/// Sheet wrapper with its own navigation bar.
struct QQMusicWebLoginSheet: View {
    var onCookie: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            QQMusicWebLoginView(onCookie: { cookie in
                onCookie(cookie)
                dismiss()
            }, reloadToken: reloadToken)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("ui.qqmusic.web_login.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("ui.common.cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("ui.qqmusic.web_login.reload")
                }
            }
            .safeAreaInset(edge: .top) {
                Text("ui.qqmusic.web_login.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
    }
}
