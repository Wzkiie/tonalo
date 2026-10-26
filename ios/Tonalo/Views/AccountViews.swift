import SwiftUI

/// "Who's listening?" – shown on start when several accounts exist.
struct AccountPickerView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 36) {
                Text("Who’s listening?").font(.largeTitle.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 24)], spacing: 28) {
                    ForEach(app.accounts) { acc in
                        Button { app.select(acc.id) } label: {
                            VStack(spacing: 10) {
                                Text(String(acc.username.prefix(1)).uppercased())
                                    .font(.system(size: 44, weight: .bold)).foregroundStyle(.black)
                                    .frame(width: 104, height: 104)
                                    .background(avatarColor(acc.username), in: Circle())
                                    .overlay(Circle().stroke(Color.white, lineWidth: acc.id == app.currentId ? 3 : 0).padding(-5))
                                Text(acc.username).font(.headline)
                                Text(acc.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button { adding = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 36)).frame(width: 104, height: 104)
                                .background(Color(white: 0.17), in: Circle())
                            Text("Add account").font(.headline)
                            Text(" ").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                if app.current != nil {
                    Button("Cancel") { app.showsAccountPicker = false }
                }
            }
            .sheet(isPresented: $adding) { NavigationStack { AccountEditorView(account: nil) } }
        }
    }
}

/// Add or edit a server login. Home address and custom headers sit on their own pages, so the form stays short.
struct AccountEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account?

    @State private var server = ""
    @State private var localServer = ""
    @State private var username = ""
    @State private var password = ""
    @State private var headers: [HeaderField] = []
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false

    private var canSave: Bool { !saving && !server.isEmpty && !username.isEmpty && (account != nil || !password.isEmpty) }
    private var namedHeaders: [HeaderField] { headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        Form {
            if account == nil && app.accounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tonalo").font(.largeTitle.bold())
                        Text("Connect to your Navidrome or Subsonic server.").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            Section("Server") {
                TextField("music.example.com or 192.168.1.10:4533", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Login") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(account == nil ? "Password" : "Password (leave empty to keep)", text: $password)
            }
            Section {
                NavigationLink { HomeAddressView(address: $localServer) } label: {
                    LabeledContent("Address at home", value: localServer.isEmpty ? String(localized: "Off") : localServer)
                }
                NavigationLink { HeadersView(headers: $headers, server: server) } label: {
                    LabeledContent("Custom headers", value: namedHeaders.isEmpty ? String(localized: "None") : "\(namedHeaders.count)")
                }
            } header: {
                Text("Advanced")
            } footer: {
                if sendsHeadersUnencrypted {
                    Label("This address uses http, so your custom headers would travel unencrypted over the internet. Use https.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let error { Section { Text(error).foregroundStyle(.red) } }

            if account == nil {
                Section {
                    Button { Task { await save() } } label: {
                        HStack { Spacer(); if saving { ProgressView() } else { Text("Sign in").bold() }; Spacer() }
                    }
                    .disabled(!canSave)
                }
            } else {
                Section {
                    Button("Remove account", role: .destructive) { confirmRemove = true }
                        .frame(maxWidth: .infinity)
                        .confirmationDialog("Remove this account?", isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove account", role: .destructive) {
                                if let account { dismiss(); app.remove(account) }
                            }
                        } message: {
                            Text("Its downloads and everything Tonalo keeps for it are deleted from this iPhone. Nothing changes on your server.")
                        }
                }
            }
        }
        .navigationTitle(account == nil ? "Add account" : "Edit account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Pushed from the settings it has a back button; only the sheet for a new account needs Cancel
            if account == nil && !app.accounts.isEmpty {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            if account != nil {
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.bold().disabled(!canSave) }
                }
            }
        }
        .onAppear {
            guard let a = account, server.isEmpty else { return }
            server = a.serverURL; username = a.username; headers = a.headers; localServer = a.localURL ?? ""
        }
    }

    /// Custom headers usually hold secrets – on plain http to a public address anyone on the way could read them.
    private var sendsHeadersUnencrypted: Bool {
        server.lowercased().hasPrefix("http://") && !SubsonicClient.isLocal(server) && !namedHeaders.isEmpty
    }

    private func save() async {
        saving = true; error = nil
        var acc = account ?? Account(serverURL: "", username: "", salt: "", token: "")
        acc.serverURL = SubsonicClient.normalize(server)
        acc.localURL = SubsonicClient.normalizeLocal(localServer)
        acc.username = username.trimmingCharacters(in: .whitespaces)
        acc.headers = namedHeaders
        if !password.isEmpty {
            let t = SubsonicClient.makeToken(password: password)
            acc.salt = t.salt; acc.token = t.token
        }
        do {
            try await app.save(acc)
            dismiss()
        } catch let first {
            // No scheme typed and https didn't connect at all (typical for an IP in the home network): try plain http.
            // Only for home-network addresses – for a public one, someone blocking https could otherwise
            // make the app send the login and custom headers unencrypted.
            let typedScheme = server.lowercased().contains("://")
            if !typedScheme, first is URLError, !SubsonicClient.isLocal(server) {
                self.error = String(localized: "The server couldn’t be reached over https. If it really only runs on http, type the address with http:// at the start.")
            } else if !typedScheme, first is URLError {
                acc.serverURL = "http://" + acc.serverURL.dropFirst("https://".count)
                do {
                    try await app.save(acc)
                    server = acc.serverURL
                    dismiss()
                } catch {
                    self.error = first.localizedDescription
                }
            } else {
                self.error = first.localizedDescription
            }
        }
        saving = false
    }
}

/// Second address for the home network, used on Wi-Fi when it answers.
private struct HomeAddressView: View {
    @Binding var address: String

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.10:4533", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("On Wi-Fi, Tonalo uses this address whenever it answers – faster, and without your proxy. Custom headers aren’t sent to it. Leave it empty to always use the server address.")
            }
        }
        .navigationTitle("Address at home")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Extra HTTP headers for Cloudflare Access, Authelia and similar proxies.
private struct HeadersView: View {
    @Binding var headers: [HeaderField]
    let server: String
    @State private var revealed: Set<UUID> = []

    var body: some View {
        Form {
            Section {
                ForEach($headers) { $h in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Header name", text: $h.name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                        HStack {
                            Group {
                                if revealed.contains(h.id) {
                                    TextField("Value", text: $h.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                                } else {
                                    SecureField("Value", text: $h.value)
                                }
                            }
                            .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                            Button { toggleReveal(h.id) } label: { Image(systemName: revealed.contains(h.id) ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { headers.remove(atOffsets: $0) }
            } footer: {
                if !headers.isEmpty { Text("Swipe left to remove a header.") }
            }
            Section {
                Button { headers.append(HeaderField(name: "", value: "")) } label: { Label("Add header", systemImage: "plus") }
                Button { addCloudflare() } label: { Label("Add Cloudflare Access headers", systemImage: "cloud") }
            } footer: {
                Text("Sent with every request, including streaming and cover art. For Cloudflare Access, create a service token in Zero Trust and paste its Client ID and Client Secret. Values are stored in the Keychain.")
            }
        }
        .navigationTitle("Custom headers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleReveal(_ id: UUID) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    private func addCloudflare() {
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret"] where !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers.append(HeaderField(name: name, value: ""))
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var app = app
        List {
            if let acc = app.current {
                Section {
                    NavigationLink { AccountEditorView(account: acc) } label: {
                        HStack(spacing: 14) {
                            Avatar(name: acc.username, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(acc.username).font(.title3.bold())
                                Text(acc.host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                if app.atHome {
                                    Label("Connected at home", systemImage: "house.fill").font(.caption).foregroundStyle(Color.accent)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Accounts") {
                ForEach(app.accounts.filter { $0.id != app.currentId }) { acc in
                    Button { app.select(acc.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(name: acc.username, size: 32)
                            VStack(alignment: .leading) {
                                Text(acc.username).foregroundStyle(.white)
                                Text(acc.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("Switch").font(.subheadline).foregroundStyle(Color.accent)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { app.remove(acc) }
                    }
                }
                Button { adding = true } label: { Label("Add account", systemImage: "plus") }
            }
            Section("Audio quality") {
                NavigationLink { QualityPicker(title: "Streaming on Wi-Fi", selection: $app.wifiQuality) } label: {
                    LabeledContent("Wi-Fi", value: app.wifiQuality.title)
                }
                NavigationLink { QualityPicker(title: "Streaming on cellular", selection: $app.cellularQuality) } label: {
                    LabeledContent("Cellular", value: app.cellularQuality.title)
                }
                NavigationLink { QualityPicker(title: "Download quality", selection: Bindable(app.downloads).quality) } label: {
                    LabeledContent("Downloads", value: app.downloads.quality.title)
                }
            }
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Crossfade", value: app.crossfade == 0 ? String(localized: "Off") : "\(app.crossfade) s")
                    Slider(value: Binding(get: { Double(app.crossfade) }, set: { app.crossfade = Int($0) }), in: 0...12, step: 1)
                        .tint(.accent)
                }
                Picker("Volume leveling", selection: $app.volumeLeveling) {
                    ForEach(VolumeLeveling.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.navigationLink)
                Toggle("Scrobble played songs", isOn: $app.scrobble)
            } header: {
                Text("Playback")
            } footer: {
                Text("Volume leveling uses the ReplayGain tags of your files. Scrobbling tells your server what you listened to.")
            }
            Section {
                NavigationLink { DownloadsView() } label: {
                    LabeledContent("Downloaded music", value: ByteCountFormatter.string(fromByteCount: app.downloads.totalBytes, countStyle: .file))
                }
                Toggle("Download over cellular", isOn: Bindable(app.downloads).allowCellular)
            } header: { Text("Offline") } footer: {
                Text("Downloads keep going in the background. Without cellular, they wait for Wi-Fi.")
            }
            Section {
                NavigationLink("Appearance") { AppearanceView() }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Link(destination: URL(string: "https://github.com/Wzkiie/tonalo")!) {
                    HStack { Text("Tonalo on GitHub").foregroundStyle(.white); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
                }
            } header: { Text("About") } footer: {
                Text("Unofficial client, not affiliated with Navidrome.")
            }
            if app.current != nil {
                Section {
                    Button("Log out", role: .destructive) { confirmLogout = true }
                        .frame(maxWidth: .infinity)
                        .logoutDialog(isPresented: $confirmLogout)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $adding) { NavigationStack { AccountEditorView(account: nil) } }
    }
}

extension View {
    /// Asks before signing the current account out – that also deletes its downloads and cache.
    func logoutDialog(isPresented: Binding<Bool>, done: @escaping () -> Void = {}) -> some View {
        modifier(LogoutDialog(isPresented: isPresented, done: done))
    }
}

private struct LogoutDialog: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    let done: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
            Button("Log out", role: .destructive) {
                guard let acc = app.current else { return }
                done()
                app.remove(acc)
            }
        } message: {
            Text("Downloads and everything Tonalo keeps for this account are deleted from this iPhone. Nothing changes on your server.")
        }
    }

    private var title: String {
        app.current.map { String(localized: "Log out of \($0.host)?") } ?? ""
    }
}

/// Picks a quality, grouped by codec like the big apps do, with the data an hour of music takes.
private struct QualityPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: AudioQuality

    var body: some View {
        List {
            ForEach(AudioQuality.Codec.allCases.filter(\.available)) { codec in
                Section {
                    ForEach(codec.levels) { q in
                        Button { selection = q } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(q.rateTitle).foregroundStyle(.white)
                                    Text(q.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if q == selection { Image(systemName: "checkmark").foregroundStyle(Color.accent).fontWeight(.semibold) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(codec.name)
                } footer: {
                    Text(codec.footer)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AudioQuality.Codec {
    var footer: LocalizedStringKey {
        switch self {
        case .original: "Formats the iPhone can’t play, such as WMA or APE, are converted to AAC 256 by your server."
        case .aac: "Converted by your server. Plays everywhere and sounds better than MP3 at the same bitrate."
        case .opus: "The most efficient codec: the best sound for the least data. Converted by your server."
        case .mp3: "For servers that don’t convert to AAC or Opus."
        }
    }
}
