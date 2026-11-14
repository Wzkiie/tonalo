package app.tonalo.android

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import app.tonalo.android.link.TvLink
import app.tonalo.android.playback.PlayerConnection
import app.tonalo.android.ui.LoginScreen
import app.tonalo.android.ui.MainScreen
import app.tonalo.android.ui.Palette
import app.tonalo.android.ui.TonaloTheme
import app.tonalo.android.ui.WhatsNew
import app.tonalo.android.ui.WhatsNewHost

class MainActivity : ComponentActivity() {
    private lateinit var player: PlayerConnection

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        player = PlayerConnection(this)
        WhatsNew.init(this)

        // Android 13+: without it, the playback notification (and its controls) stays hidden
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        setContent {
            TonaloTheme {
                Surface(Modifier.fillMaxSize(), color = Palette.canvas, contentColor = Color.White) {
                    val account by tonalo.current.collectAsState()
                    val current = account
                    if (current == null) {
                        LoginScreen()
                    } else {
                        // A new navigation for each account: pages of the old server mean nothing on the new one
                        key(current.id) { MainScreen(player) }
                        // After an update: the welcome and one page per new thing, once
                        WhatsNewHost()
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        player.connect()
        TvLink.start()
    }

    override fun onStop() {
        player.release()
        TvLink.stop()
        super.onStop()
    }
}
