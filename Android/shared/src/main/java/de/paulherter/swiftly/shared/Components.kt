package de.paulherter.swiftly.shared

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
 * Mirrors `PrimaryButtonStyle` in `Sources/Shared/Style.swift`.
 *
 * **The one filled surface of the page**: white, text in `aufAkzent`, 17 Semibold, 48 high,
 * corner 10, **no border**. Never in the accent, which carries state, never the base color of a
 * button.
 *
 * The size used to be 16, and **16 is in no scale**; 17 is the sheet heading step, and a primary
 * button is at least as loud. The text was `Color.Black` instead of `aufAkzent` (#061212), the same
 * idea but a tone that exists nowhere else.
 *
 * Pressed: white at 75 percent **and** scale 0.97. Disabled: surface `area`, text
 * `schriftSehrLeise`: dimmed, not translucent.
 */
@Composable
fun PrimaryButton(text: String, released: Boolean = true, stretches: Boolean = true,
               modifier: Modifier = Modifier,
               /** Disabled on a sheet: `erhoeht`, since `area` would be invisible there (`PrimaryButtonStyle(lockedArea:)`). */
               lockedArea: Color = Theme.area, action: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val area = if (!released) lockedArea else Color.White.copy(alpha = if (pressed) 0.75f else 1f)
    val mass by animateFloatAsState(if (pressed) Motion.PressMetric else 1f, Motion.release(), label = "druck")
    Box(
        modifier
            .then(if (stretches) Modifier.fillMaxWidth() else Modifier)
            .heightIn(min = Theme.buttonHeight)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .background(area, RoundedCornerShape(Theme.corner))
            .clickable(enabled = released, interactionSource = source, indication = null, onClick = action)
            .padding(horizontal = if (stretches) 0.dp else 28.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Theme.categoryLarge,
             color = if (released) Theme.onAccent else Theme.fontVeryQuiet)
    }
}

/**
 * Mirrors `SecondaryButtonStyle`: secondary, `area`, white text, **no border**, same height as the
 * primary button (48), 15 Medium.
 *
 * `accent = true` gives the **text** the accent, not the surface, for the second way to the same
 * goal (Quick Connect under the sign-in button). Computed: `accent` on `area` gives 8.55:1.
 *
 * Pressed: surface `pressedArea` and scale 0.97. Disabled: `schriftSehrLeise`.
 */
@Composable
fun SecondaryButton(text: String, released: Boolean = true, stretches: Boolean = true, accent: Boolean = false,
               modifier: Modifier = Modifier, action: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val mass by animateFloatAsState(if (pressed) Motion.PressMetric else 1f, Motion.release(), label = "druck")
    Box(
        modifier
            .then(if (stretches) Modifier.fillMaxWidth() else Modifier)
            .heightIn(min = Theme.buttonHeight)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .background(if (pressed) Theme.pressedArea else Theme.area, RoundedCornerShape(Theme.corner))
            .clickable(enabled = released, interactionSource = source, indication = null, onClick = action)
            .padding(horizontal = if (stretches) 0.dp else 22.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Theme.buttonText,
             color = when { !released -> Theme.fontVeryQuiet; accent -> Theme.accent; else -> Theme.font })
    }
}

/**
 * The **quiet** button: no surface, text in the accent, 15 Medium, hit area 44 high. The second
 * action of an empty state or an error notice.
 */
@Composable
fun QuietButton(text: String, modifier: Modifier = Modifier, action: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val mass by animateFloatAsState(if (pressed) Motion.PressMetric else 1f, Motion.release(), label = "druck")
    Box(
        modifier.heightIn(min = Theme.stillHeight)
            .graphicsLayer { scaleX = mass; scaleY = mass }
            .clickable(interactionSource = source, indication = null, onClick = action)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = Theme.buttonText, color = Theme.accent)
    }
}

/**
 * Mirrors `Eingabefeld` in `Sources/Shared/Components.swift`: icon 17 in a 20 wide column, 48 high,
 * surface, corner `eckeFeld`, text 15, placeholder `schriftSehrLeise`. **No border:** a field is a
 * filled capsule, not a drawn outline.
 *
 * Text and placeholder used to be 16, and **16 is in no scale**; the line in a field is body text,
 * so 15. The icon used `Color.White.copy(alpha = 0.42f)` (3.9:1 on `area`); `schriftSehrLeise`
 * has the same rank as the full value, 5.25:1.
 */
@Composable
fun InputField(
    text: String, change: (String) -> Unit, symbol: Glyph, placeholder: String,
    secret: Boolean = false, address: Boolean = false, completion: () -> Unit = {}
) {
    // **The whole surface takes the tap**, not just the text line, as on iPhone. Before, a tap beside
    // the line did not place a cursor.
    val focus = remember { FocusRequester() }
    if (secret) VisibilityProtection()
    Row(
        Modifier.fillMaxWidth().height(Theme.buttonHeight).background(Theme.area, RoundedCornerShape(Theme.cornerField))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { focus.requestFocus() }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Icon 17 in a 20 wide column, so fields with differently wide icons line up.
        Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) {
            Symbol(symbol, 17.dp, color = Theme.fontVeryQuiet)
        }
        Box(Modifier.padding(start = 10.dp).fillMaxWidth()) {
            if (text.isEmpty()) Text(placeholder, style = Theme.body, color = Theme.fontVeryQuiet)
            BasicTextField(
                value = text, onValueChange = change, singleLine = true,
                textStyle = Theme.body.copy(color = Theme.font),
                cursorBrush = SolidColor(Theme.accent),
                visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(
                    keyboardType = when { secret -> KeyboardType.Password; address -> KeyboardType.Uri; else -> KeyboardType.Text },
                    autoCorrectEnabled = false, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { completion() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus)
            )
        }
    }
}
