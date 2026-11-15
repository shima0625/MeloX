import SwiftUI

/// QQ Music account screen: sign-in state, the library entry points and the
/// two ways to sign in (the site's own QR login in an in-app browser, or a
/// pasted cookie header).
struct QQMusicSettingsView: View {
    @Environment(QQMusicStore.self) private var store

    @State private var showsWebLogin = false
    @State private var showsCookieEntry = false
    @State private var cookieText = ""
    @State private var showsSignOutConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            accountSection

            if store.isSignedIn {
                librarySection
                signOutSection
            } else {
                signInSection
            }

            Section {
            } footer: {
                Text("ui.qqmusic.privacy.footer")
            }
        }
        .navigationTitle("ui.qqmusic.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.refreshSession()
            guard store.isSignedIn else { return }
            await store.loadProfile()
            await store.loadLibrary()
        }
        .onAppear {
            store.refreshSession()
            if let libraryError = store.libraryError {
                errorMessage = libraryError
            }
        }
        .sheet(isPresented: $showsWebLogin) {
            QQMusicWebLoginSheet { cookie in
                do {
                    try store.signIn(cookie: cookie)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showsCookieEntry) {
            cookieEntrySheet
        }
        .confirmationDialog(
            "ui.qqmusic.sign_out.confirm.title",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("ui.qqmusic.sign_out", role: .destructive) {
                store.signOut()
            }
            Button("ui.common.cancel", role: .cancel) {}
        } message: {
            Text("ui.qqmusic.sign_out.confirm.message")
        }
        .alert(
            "ui.qqmusic.error.title",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("ui.common.ok", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? L10n.string("ui.common.unknown_error"))
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                ArtworkImage(url: store.avatarURL, cornerRadius: 24)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        store.isSignedIn
                            ? store.displayName
                            : L10n.string("ui.qqmusic.signed_out")
                    )
                    .font(.headline)
                    if store.isSignedIn {
                        Text(
                            L10n.format(
                                "ui.qqmusic.uin_format",
                                store.uin
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isSignedIn {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("ui.qqmusic.signed_in")
                }
            }
        } header: {
            Text("ui.qqmusic.account.section")
        }
    }

    private var signInSection: some View {
        Section {
            Button {
                showsWebLogin = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ui.qqmusic.sign_in.web")
                        Text("ui.qqmusic.sign_in.web.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode")
                }
            }

            Button {
                cookieText = ""
                showsCookieEntry = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ui.qqmusic.sign_in.cookie")
                        Text("ui.qqmusic.sign_in.cookie.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
        } header: {
            Text("ui.qqmusic.sign_in.section")
        } footer: {
            Text("ui.qqmusic.sign_in.footer")
        }
    }

    private var librarySection: some View {
        Section {
            NavigationLink {
                QQMusicLibraryView(kind: .playlists)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ui.qqmusic.library.playlists")
                        Text("ui.qqmusic.library.playlists.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }

            NavigationLink {
                QQMusicLibraryView(kind: .recommended)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ui.qqmusic.library.recommended")
                        Text("ui.qqmusic.library.recommended.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
            }

            NavigationLink {
                QQMusicLibraryView(kind: .rankings)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ui.qqmusic.library.rankings")
                        Text("ui.qqmusic.library.rankings.subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "chart.bar.fill")
                }
            }
        } header: {
            Text("ui.qqmusic.library.section")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                showsSignOutConfirmation = true
            } label: {
                Text("ui.qqmusic.sign_out")
            }
        }
    }

    private var cookieEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "ui.qqmusic.cookie.placeholder",
                        text: $cookieText,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                } header: {
                    Text("ui.qqmusic.cookie.section")
                } footer: {
                    Text("ui.qqmusic.cookie.hint")
                }
            }
            .navigationTitle("ui.qqmusic.cookie.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ui.common.cancel") {
                        showsCookieEntry = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ui.common.save") {
                        saveCookie()
                    }
                    .disabled(
                        cookieText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }
            }
        }
    }

    private func saveCookie() {
        do {
            try store.signIn(cookie: cookieText)
            showsCookieEntry = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
