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

/// Add or edit a server login, including custom headers for Cloudflare Access and similar proxies.
struct AccountEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account?

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var headers: [HeaderField] = []
    @State private var revealed: Set<UUID> = []
    @State private var saving = false
    @State private var error: String?

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
            Section {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(account == nil ? "Password" : "Password (leave empty to keep)", text: $password)
            } header: { Text("Login") }

            Section {
                ForEach($headers) { $h in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Header name", text: $h.name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.subheadline.monospaced())
                        HStack {
                            if revealed.contains(h.id) {
                                TextField("Value", text: $h.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else {
                                SecureField("Value", text: $h.value)
                            }
                            Button { toggleReveal(h.id) } label: { Image(systemName: revealed.contains(h.id) ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .font(.subheadline.monospaced())
                    }
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button { headers.append(HeaderField(name: "", value: "")) } label: { Label("Add header", systemImage: "plus") }
                Button { addCloudflare() } label: { Label("Add Cloudflare Access headers", systemImage: "cloud") }
            } header: {
                Text("Custom headers")
            } footer: {
                Text("Sent with every request, including streaming and cover art. For Cloudflare Access, create a service token in Zero Trust and paste its Client ID and Client Secret. Values are stored in the Keychain.")
            }

            if let error { Section { Text(error).foregroundStyle(.red) } }

            Section {
                Button { Task { await save() } } label: {
                    HStack { Spacer(); if saving { ProgressView() } else { Text(account == nil ? "Sign in" : "Save").bold() }; Spacer() }
                }
                .disabled(saving || server.isEmpty || username.isEmpty || (account == nil && password.isEmpty))
            }
        }
        .navigationTitle(account == nil ? "Add account" : "Edit account")
        .toolbar {
            if !app.accounts.isEmpty { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear {
            guard let a = account, server.isEmpty else { return }
            server = a.serverURL; username = a.username; headers = a.headers
        }
    }

    private func toggleReveal(_ id: UUID) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    private func addCloudflare() {
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret"] where !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers.append(HeaderField(name: name, value: ""))
        }
    }

    private func save() async {
        saving = true; error = nil
        var acc = account ?? Account(serverURL: "", username: "", salt: "", token: "")
        acc.serverURL = SubsonicClient.normalize(server)
        acc.username = username.trimmingCharacters(in: .whitespaces)
        acc.headers = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !password.isEmpty {
            let t = SubsonicClient.makeToken(password: password)
            acc.salt = t.salt; acc.token = t.token
        }
        do {
            try await app.save(acc)
            dismiss()
        } catch let first {
            // No scheme typed and https didn't connect at all (typical for an IP in the home network): try plain http
            let typedScheme = server.lowercased().contains("://")
            if !typedScheme, first is URLError {
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

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        @Bindable var app = app
        List {
            Section("Accounts") {
                ForEach(app.accounts) { acc in
                    HStack {
                        Button { app.select(acc.id) } label: {
                            HStack(spacing: 12) {
                                Text(String(acc.username.prefix(1)).uppercased()).font(.subheadline.bold()).foregroundStyle(.black)
                                    .frame(width: 32, height: 32).background(avatarColor(acc.username), in: Circle())
                                VStack(alignment: .leading) {
                                    Text(acc.username)
                                    Text(acc.host + (acc.headers.isEmpty ? "" : " · " + String(localized: "\(acc.headers.count) headers")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if acc.id == app.currentId { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                            }
                        }
                        .buttonStyle(.plain)
                        NavigationLink("") { AccountEditorView(account: acc) }.frame(width: 20)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { app.remove(acc) }
                    }
                }
                Button { adding = true } label: { Label("Add account", systemImage: "plus") }
            }
            Section {
                NavigationLink { AppearanceView() } label: { Label("Appearance", systemImage: "paintpalette") }
            }
            Section {
                NavigationLink { DownloadsView() } label: {
                    LabeledContent {
                        Text(ByteCountFormatter.string(fromByteCount: app.downloads.totalBytes, countStyle: .file))
                    } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                }
                Picker("Download quality", selection: Bindable(app.downloads).quality) {
                    Text("Original").tag(0)
                    Text("320 kbps").tag(320)
                    Text("192 kbps").tag(192)
                    Text("128 kbps").tag(128)
                }
                Toggle("Download over cellular", isOn: Bindable(app.downloads).allowCellular)
            } header: { Text("Offline") } footer: {
                Text("Downloads keep going in the background. Without cellular, they wait for Wi-Fi.")
            }
            Section("Playback") {
                Picker("Streaming quality", selection: $app.maxBitRate) {
                    Text("Original").tag(0)
                    Text("320 kbps").tag(320)
                    Text("192 kbps").tag(192)
                    Text("128 kbps").tag(128)
                }
                Toggle("Report played songs (scrobble)", isOn: $app.scrobble)
            }
            Section {
                Link("Tonalo on GitHub", destination: URL(string: "https://github.com/Wzkiie/tonalo")!)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            } footer: {
                Text("Unofficial client, not affiliated with Navidrome.")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $adding) { NavigationStack { AccountEditorView(account: nil) } }
    }
}
