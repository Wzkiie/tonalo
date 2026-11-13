import SwiftUI

/// Setting up the DJ: who picks the songs, the key or address for it, and – before anything is sent –
/// what exactly leaves the phone.
struct DJSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var keyText = ""
    @State private var models: [String] = []
    @State private var loading = false
    @State private var testing = false
    @State private var message: String?
    @State private var asking = false
    @State private var askingShare = false

    var body: some View {
        @Bindable var dj = app.player.dj
        List {
            Section {
                Toggle("DJ", isOn: Binding(get: { dj.enabled }, set: { on in
                    if !on { dj.setEnabled(false) } else if dj.agreed(dj.provider) { dj.setEnabled(true) } else { asking = true }
                }))
                .disabled(!dj.configured)
            } footer: {
                Text("An AI model of your choice picks sets from your own library and puts them in order. It never talks. Off until you turn it on.")
            }

            Section {
                Picker("Provider", selection: $dj.provider) {
                    ForEach(DJProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.navigationLink)
                if dj.provider == .ollama {
                    TextField("Address, e.g. 192.168.1.20:11434", text: $dj.ollamaAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } else if let hint = dj.keyHint {
                    LabeledContent("API key", value: hint)
                    Button("Delete key", role: .destructive) { dj.deleteKey(); models = [] }
                } else {
                    SecureField("API key", text: $keyText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") {
                        if dj.saveKey(keyText) { keyText = "" } else { message = String(localized: "The key couldn't be saved.") }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Who picks the songs")
            } footer: {
                Text(providerNote(dj.provider))
            }

            Section {
                let choices = dj.provider.fixedModels.isEmpty ? models : dj.provider.fixedModels
                if choices.isEmpty {
                    TextField("Model name", text: $dj.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Model", selection: $dj.model) {
                        if !choices.contains(dj.model) { Text(dj.model.isEmpty ? String(localized: "Choose") : dj.model).tag(dj.model) }
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
                if dj.provider.fixedModels.isEmpty {
                    Button { Task { await loadModels() } } label: {
                        HStack { Text("Load models"); if loading { Spacer(); ProgressView() } }
                    }
                    .disabled(loading)
                }
            } header: {
                Text("Model")
            } footer: {
                if dj.provider == .anthropic { Text("Larger models choose better and cost more per set.") }
            }

            Section {
                NavigationLink("Show what is sent") { DJPreviewView().canvasBackground() }
                Button { Task { await test() } } label: {
                    HStack { Text("Test"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(testing || !dj.configured)
            } footer: {
                Text("Sent per set: title, artist, album, genre, year and the favorite mark of about 150 songs, the last few songs the DJ played, and your wish if you type one. Never sent: your server address, your login, covers, your listening history or anything about audiobooks. At most 20 requests an hour.")
            }

            Section {
                Toggle("Use on paired devices", isOn: Binding(get: { dj.shareWithDevices }, set: { on in
                    if on { askingShare = true } else { dj.shareWithDevices = false }
                }))
                .disabled(!dj.enabled)
            } footer: {
                Text("Your own TV and computers paired with this account get the DJ too. Turned off, they lose it again the next time they are connected.")
            }

            if dj.provider.needsKey {
                Section {} footer: {
                    // Two texts, not one chosen with ?: – only a text written out here is looked up in the translations
                    if dj.shareWithDevices {
                        Text("Your key is stored in the keychain of this iPhone and on your paired devices. It is not shown again, and only ever sent to \(dj.recipient). Tip: create a key just for Tonalo and set a spending limit with the provider.")
                    } else {
                        Text("Your key is stored in the keychain of this iPhone only. It is not synced, not shown again, and only ever sent to \(dj.recipient). Tip: create a key just for Tonalo and set a spending limit with the provider.")
                    }
                }
            }
        }
        .navigationTitle("DJ")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: dj.provider) { models = []; keyText = "" }
        .alert("Send song details to \(dj.recipient)?", isPresented: $asking) {
            Button("Agree and turn on") { dj.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For every set, Tonalo sends title, artist, album, genre, year and the favorite mark of about 150 of your songs, which songs the DJ played last, and your wish, directly from this iPhone to \(dj.recipient). What happens to it there follows that provider's terms. Tonalo itself receives nothing.")
        }
        .alert("Use the DJ on your paired devices?", isPresented: $askingShare) {
            Button("Share") { dj.shareWithDevices = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            if dj.provider.needsKey {
                Text("Provider, model and your key go to the TVs and computers paired with this account, encrypted, and only inside your home network. They then send song details to \(dj.recipient) themselves. On a computer the key is kept in the system's protected storage; an LG TV has none, there it lies in the app's storage.")
            } else {
                Text("Provider, model and the address of your Ollama server go to the TVs and computers paired with this account. They then send song details to \(dj.recipient) themselves.")
            }
        }
        .alert("DJ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func providerNote(_ p: DJProvider) -> String {
        switch p {
        case .ollama: String(localized: "Runs on your own computer. Nothing leaves your network – the most private choice.")
        case .ollamaCloud: String(localized: "Ollama's hosted models. Needs a key from ollama.com. The song list goes to ollama.com.")
        case .anthropic: String(localized: "Needs a key from the Claude Console. The song list goes to api.anthropic.com. You pay the provider per request.")
        case .gemini: String(localized: "Needs a key from Google AI Studio. The song list goes to generativelanguage.googleapis.com.")
        }
    }

    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await app.player.dj.models()
            if models.isEmpty { message = String(localized: "No models found.") }
        } catch {
            message = (error as? DJError)?.errorDescription ?? error.userMessage ?? String(localized: "The DJ can't be reached right now.")
        }
    }

    private func test() async {
        testing = true
        message = await app.player.dj.test()
        testing = false
    }
}

/// The exact text a request would carry, built from the library right now. Nothing is sent to show it.
struct DJPreviewView: View {
    @Environment(AppModel.self) private var app
    @State private var text: String?

    var body: some View {
        ScrollView {
            if let text {
                Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).textSelection(.enabled)
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle("What is sent")
        .navigationBarTitleDisplayMode(.inline)
        .task { text = await app.player.dj.preview() }
    }
}

/// Starts the DJ from the radio cards.
struct DJCard: View {
    @Environment(AppModel.self) private var app
    let size: CGFloat

    var body: some View {
        MixCard(title: "DJ", subtitle: "Sets picked from your library", icon: "sparkles", hue: 0.88, size: size) {
            if let problem = await app.player.dj.start() { app.notify(problem) }
        }
    }
}

/// The DJ's own mark: a record, open at the top right where the needle sits, with Tonalo's three bars in the middle.
/// Drawn in the current foreground color, at any size.
struct DJMark: View {
    /// The three bars move like a level meter – while the DJ plays
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let low: [CGFloat] = [0.22, 0.40, 0.30], speed: [Double] = [5.0, 6.2, 4.4]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height), line = s * 0.1, r = (s - line) / 2
            ZStack {
                Circle().trim(from: 0, to: 0.84)
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-16.2)) // the gap of 58° sits around the top right
                    .padding(line / 2)
                Circle().frame(width: line * 1.25, height: line * 1.25)
                    .offset(x: r * 0.7071, y: -r * 0.7071)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .center, spacing: s * 0.07) {
                        ForEach(0..<3, id: \.self) { i in
                            let rest = low[i]
                            let h = animated && !reduceMotion ? 0.30 + 0.17 * sin(t * speed[i] + Double(i) * 1.9) : rest
                            Capsule().frame(width: line, height: s * h)
                        }
                    }
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The DJ's picture wherever it stands next to covers: quiet, its mark in the accent color on dark gray with a hint of it.
struct DJArt: View {
    /// While the DJ plays: the glow breathes and the bars move
    var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let glow = playing && !reduceMotion ? 0.30 + 0.16 * sin(t * 2.6) : 0.22
                    LinearGradient(colors: [Color.accent.opacity(glow), Color.accent.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                DJMark(animated: playing).foregroundStyle(Color.accent)
                    .frame(width: geo.size.width * 0.54, height: geo.size.width * 0.54)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A tap starts the DJ with a new set – or shows the player, if the DJ plays right now.
struct DJStarter<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button {
            // Only a set that plays right now is shown. An old one that was left paused is not picked up
            // again: starting the DJ always means a fresh set.
            if app.player.context?.kind == .dj, app.player.isPlaying { ui.nowPlaying(); return }
            guard !app.player.dj.busy else { return }
            Task { if let problem = await app.player.dj.start() { app.notify(problem) } }
        } label: { label() }
        .buttonStyle(.plain)
    }
}

/// The DJ at the top of the home page, for people who turned it on.
struct DJHomeTile: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let dj = app.player.dj
        let playing = app.player.context?.kind == .dj && app.player.isPlaying
        DJStarter {
            HStack(spacing: 12) {
                DJArt(playing: playing).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "DJ").font(.system(size: 14, weight: .bold))
                    Text(playing ? dj.line ?? String(localized: "Playing now") : String(localized: "Sets picked from your library"))
                        .font(.system(size: 12)).foregroundStyle(Color.subtle).lineLimit(1)
                }
                Spacer(minLength: 4)
                Group {
                    if dj.busy { ProgressView() } else {
                        Image(systemName: playing ? "waveform" : "play.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accent)
                            .symbolEffect(.variableColor.iterative, isActive: playing)
                    }
                }
                .frame(width: 44)
            }
            .frame(height: 56)
            .background(Color.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("DJ")
    }
}

/// The small DJ symbol in the player, only there for people who turned the DJ on. While something else
/// plays, a tap lets the DJ take over from the current song; while the DJ plays, it opens the way to steer it.
struct DJButton: View {
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        let dj = app.player.dj
        let active = app.player.context?.kind == .dj
        Button {
            if active { open = true; return }
            Task {
                if let problem = await dj.takeOver() { app.notify(problem) } else { app.notify(String(localized: "The DJ takes over")) }
            }
        } label: {
            ZStack {
                DJMark().frame(width: 23, height: 23).opacity(dj.busy ? 0 : 1)
                if dj.busy { ProgressView().controlSize(.small).tint(.white) }
            }
            .foregroundStyle(active ? Color.accent : .white.opacity(0.8))
        }
        .disabled(dj.busy)
        .accessibilityLabel("DJ")
        .sheet(isPresented: $open) {
            DJSheet().presentationDetents([.fraction(0.7), .large]).presentationDragIndicator(.visible).presentationBackground(Color.canvas)
        }
        #if DEBUG
        // Screenshot hook: -demoOpen djsheet opens the DJ's card once the DJ plays
        .task {
            guard ProcessInfo.processInfo.arguments.contains("djsheet") else { return }
            for _ in 0..<40 where !open {
                try? await Task.sleep(for: .seconds(0.5))
                if app.player.context?.kind == .dj, app.player.upNext.count > 2 { open = true }
            }
        }
        #endif
    }
}

/// The DJ's card: what it named the set, what comes next, and ways to steer it – a tap on a mood, or a typed wish.
private struct DJSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var wish = ""
    @State private var problem: String?

    /// Wishes that need no typing. The text in English is what goes to the model, like a typed wish would.
    private static let moods = DJ.moods

    var body: some View {
        let dj = app.player.dj
        let next = Array(app.player.upNext.prefix(8))
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        DJMark().frame(width: 15, height: 15)
                            .phaseAnimator(dj.busy ? [1.0, 0.35] : [1.0]) { mark, value in mark.opacity(value) } animation: { _ in .easeInOut(duration: 0.6) }
                        Text(verbatim: "DJ").tracking(1.5)
                        if dj.busy { Text("is choosing…").textCase(.uppercase).tracking(1.5).opacity(0.7) }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accent)
                    Text(dj.line ?? String(localized: "Sets picked from your library"))
                        .font(.system(size: 26, weight: .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 20)

                if !next.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Up next").padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(next) { song in
                                    VStack(alignment: .leading, spacing: 5) {
                                        CoverView(id: song.coverArt, size: 200).frame(width: 84, height: 84)
                                        Text(song.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        Text(song.artist ?? "").font(.system(size: 11)).foregroundStyle(Color.subtle).lineLimit(1)
                                    }
                                    .frame(width: 84, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .opacity(dj.busy ? 0.35 : 1)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    heading("Steer the DJ")
                    ChipFlow(spacing: 8) {
                        chip("More like this", icon: "plus") { await dj.change(.more) }
                        chip("Something else", icon: "shuffle") { await dj.change(.mood) }
                        ForEach(Self.moods, id: \.wish) { mood in
                            chip(LocalizedStringKey(mood.title), icon: mood.icon) { await dj.change(.wish(mood.wish)) }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("A wish, e.g. calm for the evening", text: $wish)
                            .submitLabel(.send).onSubmit { send() }
                        Button { send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black).frame(width: 32, height: 32)
                                .background(Circle().fill(Color.accent))
                        }
                        .disabled(dj.busy || wish.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Send wish")
                    }
                    .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .padding(.top, 4)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    Text("Replaces the songs after the current one. Wishes go to \(dj.recipient).")
                        .font(.system(size: 11)).foregroundStyle(Color.subtle.opacity(0.8))
                }
                .padding(.horizontal, 20)

                Button {
                    dj.stop()
                    dismiss()
                } label: {
                    Text("Stop the DJ").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.subtle)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            .padding(.top, 28).padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) { CoverTint(coverId: app.player.current?.coverArt, height: 320).opacity(0.75).ignoresSafeArea() }
        .animation(.easeOut(duration: 0.3), value: dj.busy)
        .animation(.easeOut(duration: 0.3), value: dj.line)
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).textCase(.uppercase).tracking(0.8).foregroundStyle(Color.subtle)
    }

    private func send() {
        let text = wish
        run { await app.player.dj.change(.wish(text)) }
    }

    private func chip(_ title: LocalizedStringKey, icon: String, _ work: @escaping () async -> String?) -> some View {
        Button { run(work) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accent)
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(app.player.dj.busy)
        .opacity(app.player.dj.busy ? 0.45 : 1)
    }

    /// The card stays open after a change, so the new set shows up in it.
    private func run(_ work: @escaping () async -> String?) {
        guard !app.player.dj.busy else { return }
        problem = nil
        Task {
            problem = await work()
            if problem == nil { wish = "" }
        }
    }
}

/// Lays chips out in rows, starting a new row when one is full.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = place(subviews, in: width)
        return CGSize(width: width.isFinite ? width : rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, place(subviews, in: bounds.width).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + row)
    }
}
