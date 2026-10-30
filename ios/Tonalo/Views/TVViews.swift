import SwiftUI

/// Under the player while the TV plays: where the music is, and a way to bring it back to the phone.
struct TVBar: View {
    @Environment(AppModel.self) private var app
    let name: String
    var big = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv").font(.system(size: big ? 15 : 12, weight: .semibold))
            Text("Playing on \(name)").font(.system(size: big ? 14 : 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button { app.player.continueHere() } label: {
                Label("Play on iPhone", systemImage: "iphone").font(.system(size: big ? 13 : 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.accent.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.accent)
    }
}

/// Settings → TV: TVs with Tonalo in this network, pairing with the code from the TV screen.
struct TVSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var pairing: TVLink.Device?

    var body: some View {
        let link = app.tv
        List {
            Section {
                ForEach(link.devices) { d in
                    Button { if !link.isPaired(d) { pairing = d } } label: {
                        HStack {
                            Label(d.name, systemImage: "tv").foregroundStyle(.white)
                            Spacer()
                            if link.isPaired(d) {
                                Text("Connected").foregroundStyle(Color.accent)
                            } else {
                                Text("Connect").foregroundStyle(Color.accent)
                            }
                        }
                    }
                }
                if link.devices.isEmpty {
                    Text("No TV found. Open Tonalo on your TV – it has to be in the same Wi-Fi.").foregroundStyle(.secondary)
                }
            } header: {
                Text("In this network")
            } footer: {
                Text("While the TV plays, this app shows what's playing there, and music you pick here plays on the TV. Only in your home network, nothing goes through the internet.")
            }
            let paired = link.pairings
            if !paired.isEmpty {
                Section("Paired") {
                    ForEach(paired, id: \.tv) { p in
                        Label(p.name, systemImage: "tv")
                            .swipeActions { Button("Remove", role: .destructive) { link.unpair(p.tv) } }
                    }
                }
            }
        }
        .navigationTitle("TV")
        .onAppear { link.start() }
        .sheet(item: $pairing) { PairTVView(device: $0) }
    }
}

/// The TV shows a six-digit code; typing it here pairs the two.
struct PairTVView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let device: TVLink.Device
    @State private var code = ""
    @State private var message: LocalizedStringKey?
    @State private var busy = false
    @State private var asked = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(Color.accent).padding(.top, 30)
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
        asked = await app.tv.startPairing(device)
        busy = false
        if asked { try? await Task.sleep(for: .milliseconds(350)); focused = true } else { message = "The TV isn't answering. Is Tonalo open on it?" }
    }

    private func finish() async {
        busy = true
        let result = await app.tv.finishPairing(device, code: code)
        busy = false
        switch result {
        case .ok: dismiss()
        case .wrongCode: message = "That code doesn't match. Look at the TV and try again."; code = ""
        case .expired: message = "The code has expired. Starting over …"; code = ""; await ask()
        case .failed: message = "The TV isn't answering. Is Tonalo open on it?"
        }
    }
}
