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
            .background(Color.canvas)
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
    @State private var showsOptions = false
    @FocusState private var focus: LoginField.Field?
    /// What this login connects: music, audiobooks or both, each with its own address, login and headers.
    enum Service { case music, books, both }
    @State private var service = Service.music
    @State private var bookServer = ""
    @State private var bookUsername = ""
    @State private var bookPassword = ""
    @State private var bookHeaders: [HeaderField] = []
    @State private var bookHome = ""
    /// The same headers for both, for when one Cloudflare Access token opens both servers.
    @State private var sameHeaders = false

    private var wantsMusic: Bool { service != .books }
    private var wantsBooks: Bool { service != .music }
    private var musicReady: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty }
    private var booksReady: Bool { !bookServer.isEmpty && !bookUsername.isEmpty && !bookPassword.isEmpty }
    private var canSignIn: Bool { !saving && (!wantsMusic || musicReady) && (!wantsBooks || booksReady) }
    /// Editing: an audiobooks-only account can get a music server here, which needs a password the first time.
    private var canSave: Bool {
        guard let account else { return canSignIn }
        return !saving && !server.isEmpty && !username.isEmpty && (account.hasMusic || !password.isEmpty)
    }
    private var namedBookHeaders: [HeaderField] { bookHeaders.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var namedHeaders: [HeaderField] { headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        if account == nil { login } else { form }
    }

    /// Signing in: logo, three fields and one big button – the rest hides under "More options".
    private var login: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    TonaloLogo(size: 88)
                    Text("Tonalo").font(.system(size: 34, weight: .bold))
                    Text("Your music, from your own server.").font(.callout).foregroundStyle(Color.subtle)
                }
                .padding(.top, 28)

                HStack(spacing: 8) {
                    Chip(title: "Music", selected: service == .music) { pick(.music) }
                    Chip(title: "Audiobooks", selected: service == .books) { pick(.books) }
                    Chip(title: "Both", selected: service == .both) { pick(.both) }
                }

                if wantsMusic {
                    VStack(alignment: .leading, spacing: 12) {
                        if service == .both { fieldsTitle("Music (Navidrome)") }
                        LoginField(icon: "server.rack", prompt: "Server address", text: $server,
                                   kind: .url, focus: $focus, field: .server) { focus = .username }
                        LoginField(icon: "person.fill", prompt: "Username", text: $username,
                                   kind: .username, focus: $focus, field: .username) { focus = .password }
                        LoginField(icon: "lock.fill", prompt: "Password", text: $password,
                                   kind: .password, focus: $focus, field: .password) {
                            if wantsBooks { focus = .bookServer } else if canSave { Task { await save() } }
                        }
                    }
                }
                if wantsBooks {
                    VStack(alignment: .leading, spacing: 12) {
                        if service == .both { fieldsTitle("Audiobooks (Audiobookshelf)") }
                        LoginField(icon: "book.closed.fill", prompt: "Audiobookshelf address", text: $bookServer,
                                   kind: .url, focus: $focus, field: .bookServer) { focus = .bookUsername }
                        LoginField(icon: "person.fill", prompt: "Username", text: $bookUsername,
                                   kind: .username, focus: $focus, field: .bookUsername) { focus = .bookPassword }
                        LoginField(icon: "lock.fill", prompt: "Password", text: $bookPassword,
                                   kind: .password, focus: $focus, field: .bookPassword) { if canSave { Task { await save() } } }
                    }
                }

                if wantsBooks, Self.plainOverInternet(bookServer) {
                    Label("This address uses http, so your Audiobookshelf password travels unencrypted. Only use this inside a VPN.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button { focus = nil; Task { await save() } } label: {
                    ZStack {
                        if saving { ProgressView().tint(.black) } else { Text("Sign in").font(.headline) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundStyle(canSave || saving ? Color.black : Color.subtle)
                    .background(canSave || saving ? Color.accent : Color.elevated, in: Capsule())
                    .animation(.easeOut(duration: 0.2), value: canSave)
                }
                .disabled(!canSave)

                VStack(spacing: 0) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { showsOptions.toggle() } } label: {
                        HStack {
                            Text("More options")
                            Image(systemName: "chevron.down").font(.caption.bold()).rotationEffect(.degrees(showsOptions ? 180 : 0))
                        }
                        .font(.subheadline).foregroundStyle(Color.subtle)
                    }
                    if showsOptions {
                        VStack(spacing: 0) {
                            if wantsMusic {
                            NavigationLink { HomeAddressView(address: $localServer).canvasBackground() } label: {
                                optionRow("house.fill", "Address at home", localServer.isEmpty ? String(localized: "Off") : localServer)
                            }
                            Divider().padding(.leading, 50)
                            NavigationLink { HeadersView(headers: $headers, server: server).canvasBackground() } label: {
                                optionRow("key.fill", service == .both && !sameHeaders ? "Headers for music" : "Custom headers", namedHeaders.isEmpty ? String(localized: "None") : "\(namedHeaders.count)")
                            }
                            }
                            if wantsBooks {
                                if wantsMusic { Divider().padding(.leading, 50) }
                                NavigationLink { HomeAddressView(address: $bookHome, placeholder: "192.168.1.10:13378").canvasBackground() } label: {
                                    optionRow("house.fill", service == .both ? "Audiobooks at home" : "Address at home", bookHome.isEmpty ? String(localized: "Off") : bookHome)
                                }
                            }
                            if service == .both {
                                Divider().padding(.leading, 50)
                                Toggle(isOn: $sameHeaders) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "link").foregroundStyle(Color.accent).frame(width: 22)
                                        Text("Same headers for both").foregroundStyle(.white)
                                    }
                                }
                                .padding(.horizontal, 16).frame(height: 52)
                            }
                            if service == .books || (service == .both && !sameHeaders) {
                                Divider().padding(.leading, 50)
                                NavigationLink { HeadersView(headers: $bookHeaders, server: bookServer).canvasBackground() } label: {
                                    optionRow("key.fill", service == .both ? "Headers for audiobooks" : "Custom headers", namedBookHeaders.isEmpty ? String(localized: "None") : "\(namedBookHeaders.count)")
                                }
                            }
                        }
                        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if sendsHeadersUnencrypted {
                        Label("This address uses http, so your custom headers would travel unencrypted over the internet. Use https.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange).padding(.top, 10)
                    }
                }

                if wantsBooks {
                    Text("Over a VPN or only at home? The home address is enough, like 192.168.1.10:13378.")
                        .font(.footnote).foregroundStyle(Color.subtle.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                if wantsMusic {
                Text("For example music.example.com or 192.168.1.10:4533. Works with Navidrome and other Subsonic servers. Your password isn’t stored – only a salted token, in the Keychain.")
                    .font(.footnote).foregroundStyle(Color.subtle.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
                } else {
                    Text("The password is only used to sign in and isn't stored. Tonalo keeps a login token in the Keychain, only on this iPhone.")
                        .font(.footnote).foregroundStyle(Color.subtle.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            ZStack {
                Color.canvas
                RadialGradient(colors: [Color.accent.opacity(0.38), .clear], center: .top, startRadius: 0, endRadius: 460)
            }
            .ignoresSafeArea()
        }
        .toolbar {
            // The sheet for a second account can be closed; the very first sign-in can't
            if !app.accounts.isEmpty { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // Test hook against the stand-in servers: -demoLogin "<music address>|<books address>|<header name>"
        // Sign-in values come from the mocks; the header is shared, so one token opens both.
        .onAppear {
            let parts = (UserDefaults.standard.string(forKey: "demoLogin") ?? "").components(separatedBy: "|")
            guard parts.count >= 2 else { return }
            service = parts[0].isEmpty ? .books : parts[1].isEmpty ? .music : .both
            server = parts[0]; username = "demo"; password = "demo"
            bookServer = parts[1]; bookUsername = "demo"; bookPassword = "demo"
            if parts.count > 2 {
                headers = [HeaderField(name: parts[2], value: "test")]
                sameHeaders = true
                showsOptions = true
            }
        }
        #endif
    }

    static func plainOverInternet(_ address: String) -> Bool {
        address.lowercased().hasPrefix("http://") && !SubsonicClient.isLocal(address)
    }

    private func fieldsTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.subtle).padding(.leading, 4)
    }

    private func pick(_ new: Service) {
        withAnimation(.easeOut(duration: 0.2)) { service = new }
        error = nil
    }

    private func optionRow(_ icon: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Color.accent).frame(width: 22)
            Text(title).foregroundStyle(.white)
            Spacer()
            Text(value).foregroundStyle(Color.subtle).lineLimit(1)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.subtle.opacity(0.6))
        }
        .padding(.horizontal, 16).frame(height: 52)
        .contentShape(Rectangle())
    }

    private var form: some View {
        Form {
            Section("Server") {
                TextField("music.example.com or 192.168.1.10:4533", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Login") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(account?.hasMusic == true ? "Password (leave empty to keep)" : "Password", text: $password)
            }
            Section {
                NavigationLink { HomeAddressView(address: $localServer).canvasBackground() } label: {
                    LabeledContent("Address at home", value: localServer.isEmpty ? String(localized: "Off") : localServer)
                }
                NavigationLink { HeadersView(headers: $headers, server: server).canvasBackground() } label: {
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

            if account?.audiobooks != nil {
                // The audiobooks keep the account going; without music there is nothing to take out here
                if account?.hasMusic == true {
                    Section {
                        Button("Disconnect", role: .destructive) { confirmRemove = true }
                            .frame(maxWidth: .infinity)
                            .confirmationDialog("Disconnect the music server?", isPresented: $confirmRemove, titleVisibility: .visible) {
                                Button("Disconnect", role: .destructive) { dismiss(); app.disconnectMusic() }
                            } message: {
                                Text("Its downloads and everything Tonalo keeps for it are deleted from this iPhone. Nothing changes on your server.")
                            }
                    }
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
        .navigationTitle("Music server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Pushed from the settings, so the back button cancels
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { Task { await save() } }.bold().disabled(!canSave) }
            }
        }
        .onAppear {
            guard let a = account, server.isEmpty else { return }
            server = a.serverURL; username = a.hasMusic ? a.username : ""; headers = a.headers; localServer = a.localURL ?? ""
            #if DEBUG
            // Test hook: -demoAddMusic <address> fills in a music server for an audiobooks-only account
            if !a.hasMusic, let demo = UserDefaults.standard.string(forKey: "demoAddMusic") { server = demo; username = "demo"; password = "demo" }
            #endif
        }
    }

    /// Custom headers usually hold secrets – on plain http to a public address anyone on the way could read them.
    private var sendsHeadersUnencrypted: Bool {
        let musicRisk = wantsMusic && server.lowercased().hasPrefix("http://") && !SubsonicClient.isLocal(server) && !namedHeaders.isEmpty
        let sent = sameHeaders && service == .both ? namedHeaders : namedBookHeaders
        let booksRisk = wantsBooks && bookServer.lowercased().hasPrefix("http://") && !SubsonicClient.isLocal(bookServer) && !sent.isEmpty
        return musicRisk || booksRisk
    }

    private func save() async {
        // A public name here would get the login over plain http from anywhere
        if !localServer.trimmingCharacters(in: .whitespaces).isEmpty && !SubsonicClient.isLocal(localServer) {
            error = String(localized: "Only addresses in your home network work here, like 192.168.1.10 or nas.local.")
            return
        }
        if wantsBooks, !bookHome.trimmingCharacters(in: .whitespaces).isEmpty, !SubsonicClient.isLocal(bookHome) {
            error = String(localized: "Only addresses in your home network work here, like 192.168.1.10 or nas.local.")
            return
        }
        saving = true; error = nil
        // The other half of the account you're in goes into it, not into a second account to switch to
        if account == nil, service == .books, let current = app.current, current.hasMusic, current.audiobooks == nil {
            do {
                try await app.books.connect(address: bookServer, username: bookUsername.trimmingCharacters(in: .whitespaces), password: bookPassword, headers: namedBookHeaders,
                                           home: SubsonicClient.normalizeLocal(bookHome))
                bookPassword = ""
                dismiss()
            } catch {
                self.error = String(localized: "Audiobookshelf: \(error.localizedDescription)")
            }
            saving = false
            return
        }
        var acc = account ?? Account(serverURL: "", username: "", salt: "", token: "")
        if account == nil, service == .music, let current = app.current, !current.hasMusic { acc = current }
        // Both have to work before anything is saved; a failed one says which it was
        if account == nil, wantsBooks {
            do {
                let books = try await app.books.signIn(address: bookServer, username: bookUsername.trimmingCharacters(in: .whitespaces), password: bookPassword,
                                                       headers: service == .both && sameHeaders ? namedHeaders : namedBookHeaders)
                acc.audiobooks = books
                acc.audiobooks?.localURL = SubsonicClient.normalizeLocal(bookHome)
            } catch {
                self.error = String(localized: "Audiobookshelf: \(error.localizedDescription)")
                saving = false
                return
            }
        }
        if account == nil, service == .books {
            acc.username = bookUsername.trimmingCharacters(in: .whitespaces)
            do { try await app.save(acc); bookPassword = ""; dismiss() } catch { self.error = error.localizedDescription }
            saving = false
            return
        }
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
            // The music login failed: a new try signs in again, so this Audiobookshelf login isn't needed any more
            if self.error != nil, account == nil, wantsBooks, let books = acc.audiobooks { app.books.logout(books) }
        }
        saving = false
    }
}

/// The app icon drawn in SwiftUI, so it follows the accent color. The bars breathe gently.
struct TonaloLogo: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    // Bar heights of the icon, relative to its size
    private let heights: [CGFloat] = [0.21, 0.375, 0.54, 0.335, 0.19]
    private let swing: [CGFloat] = [1.25, 0.85, 1.1, 0.8, 1.3]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color.accent)
            .frame(width: size, height: size)
            .overlay {
                HStack(spacing: size * 0.045) {
                    ForEach(heights.indices, id: \.self) { i in
                        Capsule().fill(Color(white: 0.07))
                            .frame(width: size * 0.07, height: size * heights[i] * (moving ? swing[i] : 1))
                    }
                }
            }
            .shadow(color: Color.accent.opacity(0.45), radius: 28, y: 10)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { moving = true }
            }
            .accessibilityHidden(true)
    }
}

/// Text field of the sign-in screen: icon, rounded dark surface, keyboard and autofill set up for its kind.
private struct LoginField: View {
    enum Field { case server, username, password, bookServer, bookUsername, bookPassword }
    enum Kind { case url, username, password }

    let icon: String
    let prompt: LocalizedStringKey
    @Binding var text: String
    let kind: Kind
    var focus: FocusState<Field?>.Binding
    let field: Field
    let next: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Color.subtle).frame(width: 22)
            Group {
                if kind == .password {
                    SecureField(prompt, text: $text).textContentType(.password).submitLabel(.go)
                } else {
                    TextField(prompt, text: $text)
                        .keyboardType(kind == .url ? .URL : .default)
                        .textContentType(kind == .url ? .URL : .username)
                        .submitLabel(.next)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused(focus, equals: field)
            .onSubmit(next)
        }
        .padding(.horizontal, 16).frame(height: 54)
        .background(Color.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accent.opacity(focus.wrappedValue == field ? 0.8 : 0), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
    }
}

/// Second address for the home network, used on Wi-Fi when it answers.
struct HomeAddressView: View {
    @Binding var address: String
    var placeholder = "192.168.1.10:4533"

    var body: some View {
        Form {
            Section {
                TextField(placeholder, text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !address.trimmingCharacters(in: .whitespaces).isEmpty && !SubsonicClient.isLocal(address) {
                    Label("Only addresses in your home network work here, like 192.168.1.10 or nas.local.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("On Wi-Fi, Tonalo uses this address whenever it answers – faster, and without your proxy. Custom headers aren’t sent to it. Leave it empty to always use the server address.")
            }
        }
        .navigationTitle("Address at home")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Extra HTTP headers for Cloudflare Access, Authelia and similar proxies.
struct HeadersView: View {
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

    private var hasMusic: Bool { app.current?.hasMusic ?? false }

    var body: some View {
        List {
            if let acc = app.current {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: acc.username, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(acc.username).font(.title3.bold())
                            if app.atHome {
                                Label("Connected at home", systemImage: "house.fill").font(.caption).foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Music") {
                    NavigationLink { AccountEditorView(account: acc).canvasBackground() } label: {
                        LabeledContent("Server", value: hasMusic ? URL(string: acc.serverURL)?.host ?? acc.serverURL : String(localized: "Not connected"))
                    }
                    if hasMusic {
                        NavigationLink("Audio quality") { AudioQualitySettings().canvasBackground() }
                        NavigationLink("Playback") { PlaybackSettings().canvasBackground() }
                        NavigationLink("Offline") { OfflineSettings().canvasBackground() }
                        NavigationLink { DevicesView().canvasBackground() } label: {
                            LabeledContent("Devices", value: app.tv.pairings.first { $0.guest != true }?.name ?? String(localized: "Not connected"))
                        }
                        NavigationLink { JukeboxView().canvasBackground() } label: {
                            LabeledContent("Jukebox", value: app.jukeboxHost.running ? String(localized: "Jukebox on") : String(localized: "Off"))
                        }
                    }
                }
                Section("Audiobooks & podcasts") {
                    NavigationLink { AudiobookshelfSettingsView().canvasBackground() } label: {
                        LabeledContent("Server", value: app.books.stored?.host ?? String(localized: "Not connected"))
                    }
                    if app.books.connected {
                        NavigationLink("Playback") { BookPlaybackSettings().canvasBackground() }
                        NavigationLink { BookDownloadsView().canvasBackground() } label: {
                            LabeledContent("Downloads", value: ByteCountFormatter.string(fromByteCount: app.books.downloads.totalBytes, countStyle: .file))
                        }
                    }
                }
            }
            Section("General") {
                NavigationLink("Appearance") { AppearanceView().canvasBackground() }
            }
            Section {
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
                Button { adding = true } label: { Label("Add another account", systemImage: "plus") }
            } header: { Text("Other accounts") } footer: {
                Text("For another person on this iPhone.")
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                NavigationLink("What's New") { VersionHistoryView().canvasBackground() }
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

private struct AudioQualitySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            NavigationLink { QualityPicker(title: "Streaming on Wi-Fi", selection: $app.wifiQuality).canvasBackground() } label: {
                LabeledContent("Wi-Fi", value: app.wifiQuality.title)
            }
            NavigationLink { QualityPicker(title: "Streaming on cellular", selection: $app.cellularQuality).canvasBackground() } label: {
                LabeledContent("Cellular", value: app.cellularQuality.title)
            }
            NavigationLink { QualityPicker(title: "Download quality", selection: Bindable(app.downloads).quality).canvasBackground() } label: {
                LabeledContent("Downloads", value: app.downloads.quality.title)
            }
        }
        .navigationTitle("Audio quality")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
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
                Picker("Load next songs ahead", selection: $app.preloadCount) {
                    Text("Off").tag(0)
                    ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Autoplay", isOn: $app.autoplay)
                Toggle("Scrobble played songs", isOn: $app.scrobble)
            } footer: {
                Text("Loading ahead keeps the music going when the connection drops for a moment. Volume leveling uses the ReplayGain tags of your files. Autoplay continues with similar songs when the queue ends. Scrobbling tells your server what you listened to.")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OfflineSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                NavigationLink { DownloadsView().canvasBackground() } label: {
                    LabeledContent("Downloaded music", value: ByteCountFormatter.string(fromByteCount: app.downloads.totalBytes, countStyle: .file))
                }
                Toggle("Download over cellular", isOn: Bindable(app.downloads).allowCellular)
                NavigationLink { LibrarySyncView().canvasBackground() } label: {
                    LabeledContent("Library offline", value: app.librarySync.running ? String(localized: "Syncing…")
                                   : app.librarySync.summary.map { $0.date.formatted(.relative(presentation: .named)) } ?? String(localized: "Off"))
                }
                NavigationLink("Storage") { StorageView().canvasBackground() }
            } footer: {
                Text("Downloads keep going in the background. Without cellular, they wait for Wi-Fi.")
            }
        }
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
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

/// Loads the whole library onto the iPhone, like the big Subsonic apps do – and shows how far it got.
private struct LibrarySyncView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.librarySync
        List {
            Section {
                LabeledContent("Status") {
                    if sync.running {
                        Text("Syncing…").foregroundStyle(Color.accent)
                    } else if sync.summary != nil {
                        Text(sync.isStale ? "Out of date" : "Up to date").foregroundStyle(sync.isStale ? .orange : .green)
                    } else {
                        Text("Not synced yet")
                    }
                }
                if let summary = sync.summary {
                    LabeledContent("Last sync", value: summary.date.formatted(date: .abbreviated, time: .shortened))
                }
                if sync.running {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(sync.done), total: Double(max(sync.total, 1))).tint(.accent)
                        HStack {
                            Text(sync.phase)
                            Spacer()
                            if sync.total > 0 { Text("\(sync.done) of \(sync.total)").monospacedDigit() }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button("Stop", role: .destructive) { sync.cancel() }
                } else {
                    Button(sync.summary == nil ? "Sync library now" : "Sync again") {
                        if let client = app.client { sync.start(client) }
                    }
                    .disabled(!app.isOnline || app.client == nil)
                }
                if let error = sync.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                }
            } footer: {
                Text(sync.isStale
                     ? "The last sync is more than a month old. Sync again to pick up new music."
                     : "Loads every album, artist and playlist onto this iPhone once, so everything opens at once and without a connection. Large libraries take a few minutes. Repeat it now and then, about once a month, to pick up changes.")
            }
            if let summary = sync.summary {
                Section("On this iPhone") {
                    LabeledContent("Albums", value: "\(summary.albums)")
                    LabeledContent("Artists", value: "\(summary.artists)")
                    LabeledContent("Songs", value: "\(summary.songs)")
                    LabeledContent("Playlists", value: "\(summary.playlists)")
                    LabeledContent("Genres", value: "\(summary.genres)")
                }
            }
        }
        .navigationTitle("Library offline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Tonalo keeps on the iPhone, with a way to clear each part.
private struct StorageView: View {
    @Environment(AppModel.self) private var app
    @State private var covers: Int64 = 0
    @State private var library: Int64 = 0
    @State private var preloaded: Int64 = 0
    @State private var confirmDownloads = false

    var body: some View {
        List {
            Section {
                NavigationLink { DownloadsView().canvasBackground() } label: { LabeledContent("Downloaded music", value: bytes(app.downloads.totalBytes)) }
                if app.downloads.totalBytes > 0 {
                    Button("Delete all downloads", role: .destructive) { confirmDownloads = true }
                        .confirmationDialog("Delete all downloads?", isPresented: $confirmDownloads, titleVisibility: .visible) {
                            Button("Delete all downloads", role: .destructive) { app.downloads.removeAll() }
                        }
                }
            } footer: {
                Text("Songs you downloaded to listen offline.")
            }
            Section {
                LabeledContent("Covers", value: bytes(covers))
                Button("Clear cover cache") { ImageLoader.clearDisk(); measure() }.disabled(covers == 0)
            } footer: {
                Text("Album art, so it shows at once. At most 300 MB; the oldest go first.")
            }
            Section {
                LabeledContent("Songs loaded ahead", value: bytes(preloaded))
            } footer: {
                Text("The next songs of your queue. Swapped out by itself as you listen.")
            }
            Section {
                LabeledContent("Library", value: bytes(library))
                Button("Clear library cache") {
                    if let id = app.currentId { LibraryCache.deleteAccount(id); app.librarySync.forget(id) }
                    measure()
                }
                .disabled(library == 0)
            } footer: {
                Text("The last state of your albums, playlists and home page, so they open without waiting and offline. It fills up again as you browse.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: measure)
    }

    private func measure() {
        covers = FileManager.default.size(of: ImageLoader.folder)
        library = app.currentId.map(LibraryCache.size) ?? 0
        preloaded = FileManager.default.size(of: Prefetcher.folder)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
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
