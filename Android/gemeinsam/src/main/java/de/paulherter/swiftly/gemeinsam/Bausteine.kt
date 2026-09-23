package de.paulherter.swiftly.gemeinsam

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

/**
 * Vorlage: `HauptknopfStil` in `Sources/Shared/Stil.swift`.
 *
 * **Die eine gefuellte Flaeche der Seite** (BRAND 5): weiss, Schrift in `aufAkzent`,
 * 17 Semibold, 48 hoch, Ecke 10, **kein Rand**. Nie im Akzent — der traegt Zustand,
 * nie die Grundfarbe eines Knopfs.
 *
 * Der Grad stand hier auf 16, und **16 steht in keiner Leiter**; 17 ist die Stufe der
 * Blattrubrik, und ein Hauptknopf ist mindestens so laut. Die Schrift war `Color.Black`
 * statt `aufAkzent` (#061212) — derselbe Gedanke, aber ein Ton, den es sonst nirgends gibt.
 *
 * Gedrueckt: Weiss auf 75 Prozent **und** Massstab 0,97. Gesperrt: Flaeche `flaeche`,
 * Schrift `schriftSehrLeise` — gedaempft, nicht durchscheinend.
 */
@Composable
fun Hauptknopf(text: String, freigegeben: Boolean = true, dehnt: Boolean = true,
               modifier: Modifier = Modifier, aktion: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val flaeche = if (!freigegeben) Stil.flaeche else Color.White.copy(alpha = if (gedrueckt) 0.75f else 1f)
    val mass by animateFloatAsState(if (gedrueckt) Bewegung.DRUCKMASS else 1f, Bewegung.loslassen(), label = "druck")
    Box(
        modifier
            .then(if (dehnt) Modifier.fillMaxWidth() else Modifier)
            .heightIn(min = Stil.knopfHoehe)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .background(flaeche, RoundedCornerShape(Stil.ecke))
            .clickable(enabled = freigegeben, interactionSource = quelle, indication = null, onClick = aktion)
            .padding(horizontal = if (dehnt) 0.dp else 28.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Stil.rubrikGross,
             color = if (freigegeben) Stil.aufAkzent else Stil.schriftSehrLeise)
    }
}

/**
 * Vorlage: `NebenknopfStil` — zweitrangig: `flaeche`, weisse Schrift, **kein Rand**,
 * dieselbe Hoehe wie der Hauptknopf (48), 15 Medium.
 *
 * `akzent = true` gibt der **Schrift** den Akzent, nicht der Flaeche — fuer den zweiten
 * Weg zum selben Ziel (Quick Connect unter dem Anmeldeknopf). Gerechnet: `akzent` auf
 * `flaeche` traegt 8,55:1.
 *
 * Gedrueckt: Flaeche `gedruecktFlaeche` und Massstab 0,97. Gesperrt: `schriftSehrLeise`.
 */
@Composable
fun Nebenknopf(text: String, freigegeben: Boolean = true, dehnt: Boolean = true, akzent: Boolean = false,
               modifier: Modifier = Modifier, aktion: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val mass by animateFloatAsState(if (gedrueckt) Bewegung.DRUCKMASS else 1f, Bewegung.loslassen(), label = "druck")
    Box(
        modifier
            .then(if (dehnt) Modifier.fillMaxWidth() else Modifier)
            .heightIn(min = Stil.knopfHoehe)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .background(if (gedrueckt) Stil.gedruecktFlaeche else Stil.flaeche, RoundedCornerShape(Stil.ecke))
            .clickable(enabled = freigegeben, interactionSource = quelle, indication = null, onClick = aktion)
            .padding(horizontal = if (dehnt) 0.dp else 22.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Stil.knopftext,
             color = when { !freigegeben -> Stil.schriftSehrLeise; akzent -> Stil.akzent; else -> Stil.schrift })
    }
}

/**
 * Der **stille** Knopf: keine Flaeche, Schrift im Akzent, 15 Medium, Trefferflaeche 44 hoch
 * (BAUTEILE 6). Die zweite Handlung eines Leerzustands oder eines Stoerhinweises.
 */
@Composable
fun StillerKnopf(text: String, modifier: Modifier = Modifier, aktion: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val mass by animateFloatAsState(if (gedrueckt) Bewegung.DRUCKMASS else 1f, Bewegung.loslassen(), label = "druck")
    Box(
        modifier.heightIn(min = Stil.stillHoehe)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clickable(interactionSource = quelle, indication = null, onClick = aktion)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Stil.knopftext, color = Stil.akzent)
    }
}

/**
 * Vorlage: `Eingabefeld` in `Sources/Shared/Bausteine.swift` — Zeichen 17 in 20 Breite,
 * 48 hoch, Flaeche, Ecke `eckeFeld`, Text 15, Platzhalter `schriftSehrLeise`.
 * **Kein Rand:** ein Feld ist eine gefuellte Kapsel, kein gezeichneter Rahmen.
 *
 * Text und Platzhalter standen auf 16 — **16 steht in keiner Leiter**; die Zeile in einem
 * Feld ist Fliesstext, also 15. Das Zeichen trug `Color.White.copy(alpha = 0.42f)`
 * (3,9:1 auf `flaeche`); `schriftSehrLeise` ist derselbe Rang als voller Wert, 5,25:1.
 */
@Composable
fun Eingabefeld(
    text: String, aenderung: (String) -> Unit, symbol: Zeichen, platzhalter: String,
    geheim: Boolean = false, adresse: Boolean = false, abschluss: () -> Unit = {}
) {
    // **Die ganze Flaeche nimmt den Tipp an**, nicht nur die Textzeile — wie auf
    // dem iPhone. Vorher setzte ein Tipp neben die Zeile keinen Cursor.
    val fokus = remember { FocusRequester() }
    Row(
        Modifier.fillMaxWidth().height(Stil.knopfHoehe).background(Stil.flaeche, RoundedCornerShape(Stil.eckeFeld))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { fokus.requestFocus() }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Zeichen 17 in einer 20 breiten Spalte — so fluchten Felder mit
        // verschieden breiten Zeichen untereinander (BAUTEILE 6).
        Box(Modifier.width(Stil.zeichenSpalte), contentAlignment = Alignment.Center) {
            Symbol(symbol, 17.dp, farbe = Stil.schriftSehrLeise)
        }
        Box(Modifier.padding(start = 10.dp).fillMaxWidth()) {
            if (text.isEmpty()) Text(platzhalter, style = Stil.koerper, color = Stil.schriftSehrLeise)
            BasicTextField(
                value = text, onValueChange = aenderung, singleLine = true,
                textStyle = Stil.koerper.copy(color = Stil.schrift),
                cursorBrush = SolidColor(Stil.akzent),
                visualTransformation = if (geheim) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(
                    keyboardType = when { geheim -> KeyboardType.Password; adresse -> KeyboardType.Uri; else -> KeyboardType.Text },
                    autoCorrectEnabled = false, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { abschluss() }),
                modifier = Modifier.fillMaxWidth().focusRequester(fokus)
            )
        }
    }
}
