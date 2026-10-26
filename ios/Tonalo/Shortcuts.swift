import AppIntents

/// Siri phrases and the Shortcuts app entry (also usable on the Action button).
struct TonaloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FavoriteCurrentSongIntent(),
                    phrases: ["Add this song to my favorites in \(.applicationName)",
                              "Like this song in \(.applicationName)"],
                    shortTitle: "Favorite song",
                    systemImageName: "heart.fill")
    }
}
