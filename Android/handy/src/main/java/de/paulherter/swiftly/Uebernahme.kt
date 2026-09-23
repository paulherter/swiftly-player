package de.paulherter.swiftly

import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Staerke
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.uebersetzt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** Ein Angebot aus `Kern.uebernahmeAngebote` — die Stelle stammt aus der Abfrage, nicht aus einer spaeteren. */
data class Angebot(val sitzung: String, val itemID: String, val geraet: String?, val art: String,
                   val titelzeile: String, val stelle: Double, val stelleText: String)

/** Vorlage: `Uebernahmemodell.einmalFragen`. Solange hier etwas laeuft, wird nicht gefragt — wer zusieht, fragt nicht. */
suspend fun SwiftlyAnwendung.angeboteHolen() {
    if (spiel.value != null) return
    angebote.value = runCatching {
        JSONArray(withContext(Dispatchers.IO) { kern.uebernahmeAngebote().await() }).let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map {
                Angebot(it.getString("id"), it.getString("itemID"), it.feldText("geraet"), it.getString("art"),
                        it.getString("titelzeile"), it.optDouble("stelle", 0.0), it.optString("stelleText"))
            }
        }
    }.getOrDefault(emptyList())
}

private fun zeichen(art: String): Zeichen = when (art) {
    "telefon" -> Zeichen.Telefon
    "tablet" -> Zeichen.Tablet
    "rechner" -> Zeichen.Laptop
    "fernseher" -> Zeichen.Fernseher
    else -> Zeichen.AbspielenFernseher
}

/**
 * Vorlage: das Uebernahmezeichen in `Kopfziele` (`Stil.swift`) — **auf jeder Wurzelseite**, nicht
 * nur auf der Startseite: wer in „Filme" steht, waehrend im Wohnzimmer etwas laeuft, soll es auch
 * dort sehen. **Kuehl, nicht Akzent**: der Akzent sagt „hier laeuft was", dieses Zeichen „woanders".
 * Ein Geraet: ein Tipp uebernimmt. Mehrere: erst waehlen. Erst das andere Geraet anhalten, dann
 * hier starten — scheitert das Anhalten, startet hier nichts.
 */
@Composable
fun Uebernahmezeichen(app: SwiftlyAnwendung) {
    val angebote = app.angebote.value
    val kontext = LocalContext.current
    val lauf = rememberCoroutineScope()
    var uebernimmt by remember { mutableStateOf(false) }
    fun uebernehmen(a: Angebot) {
        if (uebernimmt) return
        uebernimmt = true
        lauf.launch {
            val grund = withContext(Dispatchers.IO) { app.kern.uebernehmen(a.sitzung).await() }
            if (grund.isEmpty()) {
                app.angebote.value = emptyList()
                app.spiel.value = Abspielwunsch(a.itemID, a.stelle)
            } else Toast.makeText(kontext, fehlertext(grund), Toast.LENGTH_LONG).show()
            uebernimmt = false
        }
    }
    AnimatedVisibility(angebote.isNotEmpty(),
        enter = fadeIn(tween(220, easing = EaseInOut)) + scaleIn(tween(220, easing = EaseInOut), initialScale = 0.85f),
        exit = fadeOut(tween(220, easing = EaseInOut)) + scaleOut(tween(220, easing = EaseInOut), targetScale = 0.85f)) {
        val erstes = angebote.firstOrNull()
        Box(Modifier.size(44.dp).antippen {
                if (angebote.size == 1) erstes?.let { uebernehmen(it) }
                else app.blatt.value = Blattwunsch(uebersetzt("Wo weiterschauen?"),
                    angebote.map { Wahl(it.sitzung, listOfNotNull(it.geraet ?: uebersetzt("Gerät"), it.titelzeile, it.stelleText.ifEmpty { null }).joinToString(" · ")) },
                    null, angebote.associate { it.sitzung to zeichen(it.art) }) { s -> angebote.firstOrNull { it.sitzung == s }?.let { uebernehmen(it) } }
            }, contentAlignment = Alignment.Center) {
            Symbol(zeichen(erstes?.art ?: ""), 20.dp, farbe = Stil.akzent, beschreibung = uebersetzt("Hier weiterschauen"))
        }
    }
}
