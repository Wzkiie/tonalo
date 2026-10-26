import AppIntents

/// Adds the song that is playing to the favorite songs. Used by the lock screen / Control Center button
/// and by Siri. As an audio playback intent it always runs inside the app, where the player lives –
/// the control extension only needs to know the type.
struct FavoriteCurrentSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Add song to favorites"
    static let description = IntentDescription("Adds the song that is playing in Tonalo to your favorite songs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        let app = AppModel.shared
        guard let song = app.player.current else { return .result(dialog: "Nothing is playing in Tonalo.") }
        if song.starred != nil { return .result(dialog: "“\(song.title)” is already in your favorite songs.") }
        guard await app.setFavorite(song, true) else { return .result(dialog: "Couldn’t reach your music server.") }
        return .result(dialog: "Added “\(song.title)” to your favorite songs.")
        #endif
    }
}
