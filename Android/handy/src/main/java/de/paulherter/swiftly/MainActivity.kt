package de.paulherter.swiftly

import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import de.paulherter.swiftly.kern.SwiftlyKern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * **Die Proben aus Phase 1** — Kern ueber JNI und libVLC in Compose.
 *
 * Beides meldet ins Logcat (Tag „Swiftly"), damit es ohne Bildschirmfoto
 * geprueft werden kann: `adb logcat -s Swiftly`.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            var zeile by remember { mutableStateOf("Frage den Server …") }
            LaunchedEffect(Unit) {
                zeile = try {
                    withContext(Dispatchers.IO) {
                        SwiftlyKern.serverPruefen("https://tv.paulherter.de").await()
                    }
                } catch (e: Throwable) {
                    "Fehler: ${e.message ?: e::class.java.simpleName}"
                }
                Log.i("Swiftly", "Kern-Probe: $zeile")
            }
            Column(Modifier.fillMaxSize().background(Color(0xFF0B0B0D)).padding(top = 48.dp)) {
                Text(zeile, color = Color.White, modifier = Modifier.padding(16.dp))
                VLCProbe(Modifier.fillMaxWidth().aspectRatio(16f / 9f))
            }
        }
    }
}

/**
 * libVLC in einem `AndroidView`. Streamt eine oeffentliche 1080p-MKV (Matroska, wie die Dateien vom Server), bis die
 * Anmeldung steht und echte Dateien vom Server kommen.
 */
@androidx.compose.runtime.Composable
private fun VLCProbe(modifier: Modifier) {
    val context = LocalContext.current
    val vlc = remember { LibVLC(context, arrayListOf("--no-drop-late-frames", "--no-skip-frames")) }
    val spieler = remember { MediaPlayer(vlc) }
    DisposableEffect(Unit) {
        var gemeldet = false
        spieler.setEventListener { e ->
            when (e.type) {
                MediaPlayer.Event.Playing -> Log.i("Swiftly", "VLC-Probe: spielt")
                MediaPlayer.Event.TimeChanged -> if (!gemeldet && e.timeChanged > 2000) {
                    gemeldet = true
                    val spur = spieler.currentVideoTrack
                    Log.i("Swiftly", "VLC-Probe: Zeit ${e.timeChanged} ms, Video ${spur?.width}x${spur?.height} ${spur?.codec}")
                }
                MediaPlayer.Event.EncounteredError -> Log.e("Swiftly", "VLC-Probe: Fehler")
            }
        }
        onDispose {
            spieler.stop()
            spieler.detachViews()
            spieler.release()
            vlc.release()
        }
    }
    Box(modifier) {
        AndroidView(
            factory = { ctx ->
                VLCVideoLayout(ctx).also { layout ->
                    spieler.attachViews(layout, null, false, false)
                    val media = Media(vlc, Uri.parse("https://test-videos.co.uk/vids/jellyfish/mkv/1080/Jellyfish_1080_10s_1MB.mkv"))
                    spieler.media = media
                    media.release()
                    spieler.play()
                }
            },
            modifier = Modifier.fillMaxSize()
        )
    }
}
