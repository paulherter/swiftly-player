package de.paulherter.swiftly.gemeinsam

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Vorlage: `HauptknopfStil` in `Sources/Shared/Stil.swift` — weiss, schwarze Schrift, 48 hoch, Ecke 10. */
@Composable
fun Hauptknopf(text: String, freigegeben: Boolean = true, modifier: Modifier = Modifier, aktion: () -> Unit) {
    val quelle = remember { MutableInteractionSource() }
    val gedrueckt by quelle.collectIsPressedAsState()
    val flaeche = if (!freigegeben) Stil.flaeche else Color.White.copy(alpha = if (gedrueckt) 0.75f else 1f)
    Box(
        modifier.fillMaxWidth().height(48.dp)
            .background(flaeche, RoundedCornerShape(Stil.ecke))
            .clickable(enabled = freigegeben, interactionSource = quelle, indication = null, onClick = aktion),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
             color = if (freigegeben) Color.Black else Stil.schriftSehrLeise)
    }
}

/** Vorlage: `Eingabefeld` in `Sources/Shared/Bausteine.swift` — Symbol, 48 hoch, Flaeche, Ecke 12. */
@Composable
fun Eingabefeld(
    text: String, aenderung: (String) -> Unit, symbol: ImageVector, platzhalter: String,
    geheim: Boolean = false, adresse: Boolean = false, abschluss: () -> Unit = {}
) {
    // **Die ganze Flaeche nimmt den Tipp an**, nicht nur die Textzeile — wie auf
    // dem iPhone. Vorher setzte ein Tipp neben die Zeile keinen Cursor.
    val fokus = remember { FocusRequester() }
    Row(
        Modifier.fillMaxWidth().height(48.dp).background(Stil.flaeche, RoundedCornerShape(Stil.eckeFeld))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { fokus.requestFocus() }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(symbol, contentDescription = null, tint = Color.White.copy(alpha = 0.42f), modifier = Modifier.width(20.dp))
        Box(Modifier.padding(start = 10.dp).fillMaxWidth()) {
            if (text.isEmpty()) Text(platzhalter, style = TextStyle(fontSize = 16.sp), color = Stil.schriftSehrLeise)
            BasicTextField(
                value = text, onValueChange = aenderung, singleLine = true,
                textStyle = TextStyle(fontSize = 16.sp, color = Stil.schrift),
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
