package de.paulherter.swiftly

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import de.paulherter.swiftly.kern.SwiftlyKern
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext

/**
 * **Die Probe aus Phase 1:** Kotlin ruft ueber JNI in JellyfinKit.
 *
 * Beim Start fragt die App den Server ab und zeigt die Antwort. Die Zeile geht
 * zusaetzlich ins Logcat (Tag „Swiftly"), damit sie ohne Bildschirmfoto
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
            Box(Modifier.fillMaxSize().background(Color(0xFF0B0B0D)), contentAlignment = Alignment.Center) {
                Text(zeile, color = Color.White)
            }
        }
    }
}
