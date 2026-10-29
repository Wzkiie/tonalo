import SwiftUI

/// What changed in each version. Shown once after an update, and any time from Settings.
/// For a new version: add a release at the top – its version must match MARKETING_VERSION.
struct AppRelease: Identifiable {
    let version: String
    let items: [Item]
    var id: String { version }

    struct Item: Identifiable {
        let icon: String
        let color: Color
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        var id: String { icon }
    }
}

enum WhatsNew {
    static let releases: [AppRelease] = [
        AppRelease(version: "1.1.0", items: [
            .init(icon: "dot.radiowaves.left.and.right", color: .purple, title: "Endless radio",
                  text: "Start a radio from a song, an artist, a genre or your favorites. It plays more of what you listen to and like, and less of what you skip."),
            .init(icon: "antenna.radiowaves.left.and.right", color: .red, title: "Radio stations",
                  text: "The stations set up on your server play live, with the song on air. If it's in your library, one tap plays it from there."),
            .init(icon: "infinity", color: .orange, title: "Autoplay",
                  text: "When an album or playlist ends, similar songs keep playing. You can turn it off in Settings."),
            .init(icon: "line.3.horizontal", color: .blue, title: "Reorder the queue",
                  text: "Tap Edit in the queue and drag songs to where you want them."),
            .init(icon: "arrow.down.circle.fill", color: .teal, title: "Faster downloads",
                  text: "Five songs load at once, and a small counter above the player shows how far they are on every page."),
            .init(icon: "car.fill", color: .green, title: "CarPlay",
                  text: "Your music, playlists and downloads on the car screen, with a heart for your favorites."),
            .init(icon: "applewatch", color: .pink, title: "Apple Watch",
                  text: "Play, skip, like and change the volume from your wrist, and start your playlists there."),
        ]),
    ]

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var current: AppRelease? { releases.first { $0.version == currentVersion } }

    private static let key = "whatsNewSeen"

    /// After an update, once per version. A fresh install has nothing new to tell, so it only remembers the version.
    static func shouldShow(hasAccounts: Bool) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-whatsNew") { return current != nil }
        #endif
        let seen = UserDefaults.standard.string(forKey: key)
        if seen == currentVersion { return false }
        if seen == nil && !hasAccounts { markSeen(); return false }
        return current != nil
    }

    static func markSeen() { UserDefaults.standard.set(currentVersion, forKey: key) }
}

/// The sheet after an update.
struct WhatsNewSheet: View {
    let release: AppRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New in Tonalo")
                            .font(.system(size: 34, weight: .bold))
                        Text("Version \(release.version)")
                            .font(.headline).foregroundStyle(Color.subtle)
                    }
                    .padding(.top, 48)
                    ForEach(release.items) { WhatsNewRow(item: $0) }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            Button {
                dismiss()
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(Color.black)
        .presentationDragIndicator(.visible)
    }
}

private struct WhatsNewRow: View {
    let item: AppRelease.Item

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: item.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.text).font(.subheadline).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Every version, newest first – from Settings.
struct VersionHistoryView: View {
    var body: some View {
        List {
            ForEach(WhatsNew.releases) { release in
                Section {
                    ForEach(release.items) { WhatsNewRow(item: $0).padding(.vertical, 4) }
                } header: {
                    Text("Version \(release.version)")
                }
            }
        }
        .navigationTitle("What's New")
    }
}
