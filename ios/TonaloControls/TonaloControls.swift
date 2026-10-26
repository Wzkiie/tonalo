import AppIntents
import SwiftUI
import WidgetKit

@main
struct TonaloControls: WidgetBundle {
    var body: some Widget {
        FavoriteControl()
    }
}

/// Heart button for the lock screen and Control Center: adds the playing song to the favorite songs.
struct FavoriteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.wzkiie.tonalo.favorite") {
            ControlWidgetButton(action: FavoriteCurrentSongIntent()) {
                Label("Favorite song", systemImage: "heart.fill")
            }
        }
        .displayName("Favorite song")
        .description("Adds the song that is playing in Tonalo to your favorite songs.")
    }
}
