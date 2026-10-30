import SwiftUI

/// Under the player while another device plays: where the music is, and the way back.
/// The own TV: "Play on iPhone". A Jukebox as a guest: "Leave".
struct TVBar: View {
    @Environment(AppModel.self) private var app
    let name: String
    var big = false

    var body: some View {
        let guest = app.player.tvGuest
        HStack(spacing: 8) {
            Image(systemName: guest ? "person.2.wave.2" : "tv").font(.system(size: big ? 15 : 12, weight: .semibold))
            // An iPhone's Jukebox already says so in its name
            Text(guest ? (name.contains("Jukebox") ? "\(name)" : "Jukebox · \(name)") : "Playing on \(name)").font(.system(size: big ? 14 : 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button { app.player.continueHere() } label: {
                Label(guest ? "Leave" : "Play on iPhone", systemImage: guest ? "xmark" : "iphone")
                    .font(.system(size: big ? 13 : 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.accent.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.accent)
    }
}

/// Under the player while this phone hosts a Jukebox: who's in, and ending it.
struct JukeboxHostBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let host = app.jukeboxHost
        HStack(spacing: 8) {
            Image(systemName: "person.2.wave.2").font(.system(size: 12, weight: .semibold))
            Text(host.present.isEmpty ? "Jukebox · waiting for guests" : "Jukebox · \(host.present.joined(separator: ", "))")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button { host.stop() } label: {
                Text("End").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.accent.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.accent)
    }
}

/// Settings → TV & Jukebox: the own TV, hosting a Jukebox, and joining one.
struct TVSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var pairing: Pairing?
    @State private var choose: TVLink.Device?

    struct Pairing: Identifiable {
        let device: TVLink.Device
        let guest: Bool
        var id: String { device.id + (guest ? "g" : "") }
    }

    var body: some View {
        let link = app.tv
        let host = app.jukeboxHost
        List {
            Section {
                Toggle(isOn: Binding(get: { host.running }, set: { $0 ? host.start() : host.stop() })) {
                    Label("Host a Jukebox", systemImage: "person.2.wave.2")
                }
                ForEach(host.guests, id: \.keyId) { g in
                    HStack {
                        Label(g.name, systemImage: "person")
                        Spacer()
                        if host.present.contains(g.name) { Text("Here").foregroundStyle(Color.accent) }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { host.remove(g) } }
                }
            } header: {
                Text("Jukebox")
            } footer: {
                Text("Friends nearby join with a code shown on this iPhone, add songs to what's playing and skip. Works in the car too – the phones connect directly, without Wi-Fi. They need an account on the same server.")
            }
            Section {
                ForEach(link.devices) { d in
                    Button { tapped(d) } label: {
                        HStack {
                            Label(d.name, systemImage: d.isPhone ? "iphone" : "tv").foregroundStyle(.white)
                            Spacer()
                            Text(status(d)).foregroundStyle(Color.accent)
                        }
                    }
                }
                if link.devices.isEmpty {
                    Text("Nothing found. Open Tonalo on your TV, or on the iPhone hosting the Jukebox.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Your own TV: while it plays, this app shows what's playing there, and music you pick here plays on the TV. Nothing goes through the internet.")
            }
            let paired = link.pairings
            if !paired.isEmpty {
                Section("Paired") {
                    ForEach(paired, id: \.tv) { p in
                        Label(p.guest == true ? "\(p.name) (guest)" : p.name, systemImage: "link")
                            .swipeActions { Button("Remove", role: .destructive) { link.unpair(p.tv) } }
                    }
                }
            }
        }
        .navigationTitle("TV & Jukebox")
        .onAppear { link.start() }
        .sheet(item: $pairing) { PairTVView(device: $0.device, guest: $0.guest) }
        .confirmationDialog(choose?.name ?? "", isPresented: Binding(get: { choose != nil }, set: { if !$0 { choose = nil } }), titleVisibility: .visible) {
            if let d = choose {
                Button("This is my TV") { pairing = Pairing(device: d, guest: false) }
                Button("Join the Jukebox") { pairing = Pairing(device: d, guest: true) }
            }
        } message: {
            Text("Your own TV plays together with this iPhone. As a guest you add songs and skip.")
        }
    }

    private func status(_ d: TVLink.Device) -> LocalizedStringKey {
        guard let p = app.tv.pairing(for: d) else { return d.isPhone ? "Join" : "Connect" }
        if p.guest != true { return "Connected" }
        return app.tv.jukebox == d.id ? "Joined" : "Join"
    }

    private func tapped(_ d: TVLink.Device) {
        if let p = app.tv.pairing(for: d) {
            if p.guest == true && app.tv.jukebox != d.id { app.tv.join(d) }
            return
        }
        // An iPhone only hosts a Jukebox; a TV can be the own one or someone's Jukebox
        if d.isPhone { pairing = Pairing(device: d, guest: true) } else { choose = d }
    }
}

/// The other device shows a six-digit code; typing it here pairs the two.
struct PairTVView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let device: TVLink.Device
    let guest: Bool
    @State private var code = ""
    @State private var message: LocalizedStringKey?
    @State private var busy = false
    @State private var asked = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: device.isPhone ? "iphone" : "tv").font(.system(size: 44)).foregroundStyle(Color.accent).padding(.top, 30)
                Text(asked ? "Enter the code shown on \(device.name)" : "Connecting to \(device.name) …")
                    .font(.headline).multilineTextAlignment(.center)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .disabled(!asked)
                    .onChange(of: code) { _, v in
                        code = String(v.filter(\.isNumber).prefix(6))
                        if code.count == 6 { Task { await finish() } }
                    }
                if let message { Text(message).foregroundStyle(.red).font(.subheadline).multilineTextAlignment(.center) }
                if busy { ProgressView() }
                Spacer()
            }
            .padding(.horizontal, 24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .task { await ask() }
    }

    private func ask() async {
        busy = true
        asked = await app.tv.startPairing(device, guest: guest)
        busy = false
        if asked { try? await Task.sleep(for: .milliseconds(350)); focused = true } else { message = "\(device.name) isn't answering. Is Tonalo open on it?" }
    }

    private func finish() async {
        busy = true
        let result = await app.tv.finishPairing(device, code: code, guest: guest)
        busy = false
        switch result {
        case .ok: dismiss()
        case .wrongCode: message = "That code doesn't match. Look at the other screen and try again."; code = ""
        case .expired: message = "The code has expired. Starting over …"; code = ""; await ask()
        case .failed: message = "\(device.name) isn't answering. Is Tonalo open on it?"
        }
    }
}

/// On the hosting iPhone: someone wants to join – this is the code they type in.
struct JukeboxCodeView: View {
    @Environment(AppModel.self) private var app
    let request: JukeboxHost.Request

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.wave.2").font(.system(size: 40)).foregroundStyle(Color.accent).padding(.top, 34)
            Text("\(request.name) wants to join the Jukebox").font(.headline).multilineTextAlignment(.center)
            Text(request.code.prefix(3) + " " + request.code.suffix(3))
                .font(.system(size: 52, weight: .heavy, design: .monospaced))
            Text("Show this code to \(request.name).").foregroundStyle(Color.subtle)
            Button("Cancel") { app.jukeboxHost.cancelRequest() }.padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
