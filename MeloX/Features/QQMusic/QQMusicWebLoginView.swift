import SwiftUI
import WebKit

/// Loads the QQ Music site in an in-app browser so the user can sign in with
/// the QQ Music / WeChat QR code the site itself shows. Once the login cookies
/// appear, the cookie header is handed back and stored as the session.
struct QQMusicWebLoginView: UIViewRepresentable {
    var onCookie: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
            + "Mobile/15E148 Safari/604.1"
        if let url = URL(string: "https://y.qq.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookie: onCookie)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookie: (String) -> Void
        private var hasReported = false

        init(onCookie: @escaping (String) -> Void) {
            self.onCookie = onCookie
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
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

    var body: some View {
        NavigationStack {
            QQMusicWebLoginView { cookie in
                onCookie(cookie)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("ui.qqmusic.web_login.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("ui.common.cancel") {
                        dismiss()
                    }
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
