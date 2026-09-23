package de.paulherter.swiftly.gemeinsam

import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * **Jedes Symbol der App kommt von hier** — Telefon und Fernseher.
 *
 * Der Satz ist **Material Symbols Rounded** als variable Schrift
 * (`res/font/symbole_rund.ttf`, Apache 2.0, Lizenz unter `assets/lizenzen/`). Vorher stand ein
 * Mischbestand da — Material Icons in Filled und Outlined, dazu selbstgezeichnete Vektoren im
 * Player —, und jedes Zeichen hatte eine andere Groesse, Strichstaerke und Machart. Paul am
 * 22.09.: „Wir brauchen einfach mehr Konsistenz in den Symbolen, weniger selbstgemachte
 * Scheisse. Nimm die Rounded." Rounded, weil SF Symbols runde Strichenden haben.
 *
 * **Keine Stelle setzt die Achsen selbst.** Sonst laeuft es in drei Monaten wieder auseinander.
 *
 * - `wght` — die Staerke des SF Symbols an derselben Stelle am iPhone (`Staerke`).
 * - `FILL` — 1, wo das iPhone die `.fill`-Fassung nimmt; haengt am `Zeichen`, nicht am Aufruf.
 * - `opsz` — die dargestellte Groesse, zwischen 20 und 48 geklemmt: die optische Groesse passt
 *   die Strichfuehrung an, so wie SF Symbols es tun.
 * - `GRAD` — 0.
 *
 * **`groesse` ist der Punktgrad am iPhone**, nicht die Kastengroesse. Ein SF Symbol steht bei
 * Grad 17 rund 17 pt hoch; ein Material-Zeichen fuellt vom Geviert nur 20 von 24 Teilen. Der
 * Baustein setzt das Geviert deshalb 1,2-fach, damit beide neben demselben Text **optisch**
 * gleich hoch stehen. Wer `Symbol(Zeichen.Haken, 17.dp)` schreibt, bekommt, was
 * `.font(.system(size: 17))` am iPhone zeigt.
 *
 * ## Zuordnung SF Symbol → Material Symbol
 *
 * Zum Nachschlagen, nicht zum Neuwaehlen. Wo es kein gutes Gegenstueck gibt, steht der Grund.
 *
 * | SF Symbol | Material Symbols Rounded | FILL | Anmerkung |
 * |---|---|---|---|
 * | `house` | `home` | 0 |  |
 * | `film` | `movie` | 0 |  |
 * | `tv` | `tv` | 0 |  |
 * | `magnifyingglass` | `search` | 0 |  |
 * | `arrow.down.circle` | `arrow_circle_down` | 0 |  |
 * | `arrow.down.circle.fill` | `arrow_circle_down` | 1 |  |
 * | `arrow.down` | `arrow_downward` | 0 |  |
 * | `bookmark` | `bookmark` | 0 |  |
 * | `bookmark.fill` | `bookmark` | 1 |  |
 * | `person` | `person` | 0 |  |
 * | `person.fill` | `person` | 1 |  |
 * | `lock` | `lock` | 0 |  |
 * | `tag` | `sell` | 0 | SF tag ist ein Anhaenger; Material „sell" ist genau diese Form |
 * | `star` | `star` | 0 |  |
 * | `star.fill` | `star` | 1 |  |
 * | `plus` | `add` | 0 |  |
 * | `plus.circle` | `add_circle` | 0 |  |
 * | `minus` | `remove` | 0 |  |
 * | `play.fill` | `play_arrow` | 1 |  |
 * | `play.circle` | `play_circle` | 0 |  |
 * | `play.rectangle` | `smart_display` | 0 |  |
 * | `play.tv` | `live_tv` | 0 | Material hat keinen Fernseher mit Dreieck ohne Antenne |
 * | `pause.fill` | `pause` | 1 |  |
 * | `gobackward`, `gobackward.N` | `replay` | 0 | Material hat den Pfeilkreis mit Zahl nur fuer 5/10/30 — der Player setzt die Ziffer selbst hinein, fuer jede Spanne gleich |
 * | `goforward`, `goforward.N` | `replay` | 0 | gespiegelt dargestellt — Material hat kein Gegenstueck im Uhrzeigersinn |
 * | `forward.end.fill` | `skip_next` | 1 |  |
 * | `forward.end` | `skip_next` | 0 |  |
 * | `ellipsis` | `more_horiz` | 0 |  |
 * | `captions.bubble` | `subtitles` | 0 | SF ist eine Sprechblase mit Zeilen; Material „subtitles" ein Rechteck mit Zeilen |
 * | `rectangle.stack` | `stack` | 0 |  |
 * | `slider.horizontal.3` | `tune` | 0 |  |
 * | `xmark` | `close` | 0 |  |
 * | `xmark.circle` | `cancel` | 0 |  |
 * | `xmark.circle.fill` | `cancel` | 1 |  |
 * | `checkmark` | `check` | 0 |  |
 * | `checkmark.circle` | `check_circle` | 0 |  |
 * | `checkmark.circle.fill` | `check_circle` | 1 |  |
 * | `square` | `check_box_outline_blank` | 0 |  |
 * | `checkmark.square.fill` | `check_box` | 1 |  |
 * | `chevron.down` | `expand_more` | 0 |  |
 * | `chevron.up` | `expand_less` | 0 |  |
 * | `chevron.left` | `chevron_left` | 0 |  |
 * | `chevron.right` | `chevron_right` | 0 |  |
 * | `arrow.up.arrow.down` | `swap_vert` | 0 |  |
 * | `line.3.horizontal.decrease` | `filter_list` | 0 |  |
 * | `wifi` | `wifi` | 0 |  |
 * | `wifi.slash` | `wifi_off` | 0 |  |
 * | `wifi.exclamationmark` | `signal_wifi_bad` | 0 |  |
 * | `square.grid.2x2` | `grid_view` | 0 |  |
 * | `rectangle.grid.1x2` | `view_agenda` | 0 |  |
 * | `square.split.2x1` | `view_column_2` | 0 |  |
 * | `rectangle.on.rectangle` | `filter_none` | 0 |  |
 * | `link` | `link` | 0 |  |
 * | `exclamationmark.triangle.fill` | `warning` | 1 |  |
 * | `clock.arrow.circlepath` | `history` | 0 |  |
 * | `bubble.left.and.bubble.right` | `forum` | 0 |  |
 * | `arrow.counterclockwise` | `restart_alt` | 0 |  |
 * | `arrow.counterclockwise.circle` | `settings_backup_restore` | 0 |  |
 * | `arrow.clockwise` | `refresh` | 0 |  |
 * | `arrow.uturn.backward` | `undo` | 0 |  |
 * | `externaldrive.badge.xmark` | `database_off` | 0 | Material hat kein Laufwerk mit Kreuz; „database_off" traegt denselben Sinn |
 * | `externaldrive.connected.to.line.below` | `dns` | 0 |  |
 * | `internaldrive` | `hard_drive` | 0 |  |
 * | `trash` | `delete` | 0 |  |
 * | `tray` | `inbox` | 0 |  |
 * | `tray.and.arrow.down` | `move_to_inbox` | 0 |  |
 * | `text.alignleft` | `format_align_left` | 0 |  |
 * | `speaker.wave.2` | `volume_up` | 0 |  |
 * | `sparkles` | `auto_awesome` | 0 |  |
 * | `sparkle.magnifyingglass` | `search_insights` | 0 |  |
 * | `waveform.badge.magnifyingglass` | `graphic_eq` | 0 | Material hat keine Welle mit Lupe |
 * | `rectangle.and.text.magnifyingglass` | `manage_search` | 0 |  |
 * | `rectangle.portrait.and.arrow.right` | `logout` | 0 |  |
 * | `pip.fill` | `picture_in_picture_alt` | 1 |  |
 * | `laptopcomputer` | `laptop_mac` | 0 |  |
 * | `ladybug` | `bug_report` | 0 |  |
 * | `doc.text` | `description` | 0 |  |
 * | `iphone` | `mobile` | 0 |  |
 * | `ipad` | `tablet_mac` | 0 |  |
 * | `globe` | `language` | 0 |  |
 * | `gearshape` | `settings` | 0 |  |
 * | `chart.bar` | `bar_chart` | 0 |  |
 * | `chart.bar.fill` | `bar_chart` | 1 |  |
 * | `capsule` | `toggle_off` | 0 | Material hat keine blosse Kapsel; „toggle_off" ist die naechste Form |
 * | `eye.slash` | `visibility_off` | 0 |  |
 * | `info.circle` | `info` | 0 |  |
 * | `circle.lefthalf.filled` | `contrast` | 0 |  |
 * | `circle` | `radio_button_unchecked` | 0 |  |
 * | `line.3.horizontal` | `drag_handle` | 0 |  |
 * | `clock` | `schedule` | 0 |  |
 * | `antenna.radiowaves.left.and.right` | `signal_cellular_alt` | 0 |  |
 * | `desktopcomputer` | `computer` | 0 |  |
 * | `rotate.right` | `screen_rotation_alt` | 0 |  |
 * | `pencil` | `edit` | 0 |  |
 * | `eye` | `visibility` | 0 |  |
 * | `exclamationmark` | `priority_high` | 0 |  |
 */
enum class Zeichen(val code: Int, val gefuellt: Boolean, val gespiegelt: Boolean) {
    Haus(0xE88A, false, false),
    Film(0xE02C, false, false),
    Fernseher(0xE333, false, false),
    Lupe(0xE8B6, false, false),
    LadenKreis(0xF181, false, false),
    LadenKreisVoll(0xF181, true, false),
    PfeilRunter(0xE5DB, false, false),
    Lesezeichen(0xE866, false, false),
    LesezeichenVoll(0xE866, true, false),
    Person(0xE7FD, false, false),
    PersonVoll(0xE7FD, true, false),
    Schloss(0xE88D, false, false),
    Etikett(0xE54E, false, false),
    Stern(0xE838, false, false),
    SternVoll(0xE838, true, false),
    Plus(0xE145, false, false),
    PlusKreis(0xE147, false, false),
    Minus(0xE15B, false, false),
    MinusKreis(0xF08C, false, false),
    Schluessel(0xE73C, false, false),
    Abspielen(0xE037, true, false),
    AbspielenKreis(0xE038, false, false),
    AbspielenRechteck(0xF06A, false, false),
    AbspielenFernseher(0xE639, false, false),
    Pause(0xE034, true, false),
    Zurueckspulen(0xE042, false, false),
    Vorspulen(0xE042, false, true),
    Ueberspringen(0xE044, true, false),
    UeberspringenUmriss(0xE044, false, false),
    Mehr(0xE5D3, false, false),
    Untertitel(0xE048, false, false),
    Stapel(0xF609, false, false),
    Regler(0xE429, false, false),
    Kreuz(0xE14C, false, false),
    KreuzKreis(0xE5C9, false, false),
    KreuzKreisVoll(0xE5C9, true, false),
    Haken(0xE5CA, false, false),
    HakenKreis(0xE86C, false, false),
    HakenKreisVoll(0xE86C, true, false),
    Kaestchen(0xE835, false, false),
    KaestchenVoll(0xE834, true, false),
    WinkelRunter(0xE5CF, false, false),
    WinkelHoch(0xE5CE, false, false),
    WinkelLinks(0xE408, false, false),
    WinkelRechts(0xE409, false, false),
    Sortieren(0xE0C3, false, false),
    Filter(0xE152, false, false),
    Wlan(0xE63E, false, false),
    WlanAus(0xE648, false, false),
    WlanStoerung(0xF063, false, false),
    Raster(0xE9B0, false, false),
    Zeilen(0xE8E9, false, false),
    Geteilt(0xF847, false, false),
    Rechtecke(0xE3E0, false, false),
    Kette(0xE157, false, false),
    Warnung(0xE002, true, false),
    Verlauf(0xE28E, false, false),
    Gespraech(0xE0BF, false, false),
    Ruecksetzen(0xF053, false, false),
    RuecksetzenKreis(0xE8BA, false, false),
    Neuladen(0xE5D5, false, false),
    Rueckgaengig(0xE166, false, false),
    ServerWeg(0xF414, false, false),
    Server(0xE875, false, false),
    Laufwerk(0xF80E, false, false),
    Papierkorb(0xE872, false, false),
    Ablage(0xE156, false, false),
    AblageLaden(0xE168, false, false),
    Textblock(0xE236, false, false),
    Lautsprecher(0xE050, false, false),
    Funkeln(0xE65F, false, false),
    FunkelnSuche(0xF4BC, false, false),
    Wellensuche(0xE1B8, false, false),
    Textsuche(0xF02F, false, false),
    Abmelden(0xE9BA, false, false),
    BildImBild(0xE911, true, false),
    Laptop(0xE320, false, false),
    Kaefer(0xE868, false, false),
    Dokument(0xE873, false, false),
    Telefon(0xE0D4, false, false),
    Tablet(0xE331, false, false),
    Globus(0xE894, false, false),
    Zahnrad(0xE8B8, false, false),
    Balken(0xE26B, false, false),
    BalkenVoll(0xE26B, true, false),
    Kapsel(0xE9F5, false, false),
    Auge(0xE8F5, false, false),
    Info(0xE88E, false, false),
    Kontrast(0xEB37, false, false),
    Kreis(0xE836, false, false),
    Griff(0xE25D, false, false),
    Uhr(0xE192, false, false),
    Balkenempfang(0xE202, false, false),
    Rechner(0xE30A, false, false),
    Drehen(0xEBEE, false, false),
    Stift(0xE150, false, false),
    AugeOffen(0xE417, false, false),
    Ausrufezeichen(0xE645, false, false),
    ;

    val text: String get() = String(Character.toChars(code))
}

/** Die Staerke des SF Symbols am iPhone — `ultralight` 100 bis `bold` 700. */
enum class Staerke(val wght: Int) {
    Ultraleicht(100), Duenn(200), Leicht(300), Normal(400), Mittel(500), Halbfett(600), Fett(700)
}

/** Ein Schnitt je Achsenstand — Compose baut sonst fuer jedes Bild eine neue Schrift. */
private val schnitte = HashMap<Long, FontFamily>()

@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun schnitt(wght: Int, fill: Boolean, opsz: Int): FontFamily {
    val schluessel = (wght.toLong() shl 16) or ((if (fill) 1L else 0L) shl 8) or opsz.toLong()
    return schnitte.getOrPut(schluessel) {
        FontFamily(Font(R.font.symbole_rund, variationSettings = FontVariation.Settings(
            FontVariation.weight(wght),
            FontVariation.Setting("FILL", if (fill) 1f else 0f),
            FontVariation.Setting("GRAD", 0f),
            FontVariation.Setting("opsz", opsz.toFloat()),
        )))
    }
}

/**
 * Ein Symbol. `groesse` = der Grad am iPhone (siehe oben), `staerke` = seine Staerke dort.
 * `beschreibung` nur, wo das Zeichen allein steht — neben einem Text liest der Text.
 *
 * **Gesetzt wird das Zeichen, nicht eine Textzeile.** Material Symbols ist eine Schrift mit
 * Oberlaenge 1056 und Unterlaenge 96 auf einem Geviert von 960, die Glyphen sitzen aber mittig im
 * Geviert ueber der Grundlinie (Mitte bei 480). Als Textzeile mit `lineHeight` = Geviert und
 * `LineHeightStyle(Center, Trim.Both)` stand die Grundlinie trotzdem bei 1,1 Geviert unter der
 * Oberkante — jedes Zeichen sass um ein Zehntel seines Kastens zu tief, am Pixel-Emulator
 * gemessen 1,3 bis 2,5 dp, und unten stiess es an den Rand. Deshalb wird die Grundlinie hier selbst
 * gelegt: Kastenmitte plus ein halbes Geviert.
 *
 * **`requiredSize`, nicht `size`.** Wo ein Aufrufer eine engere Spalte gibt (Haken in 18, Zeichen in
 * 20), schrumpfte der Kasten mit, das Zeichen rutschte zur Seite und wurde am Rand beschnitten.
 * So behaelt es seine Groesse und steht mittig in der Spalte.
 */
@Composable
fun Symbol(zeichen: Zeichen, groesse: Dp, modifier: Modifier = Modifier, farbe: Color = Stil.schrift,
           staerke: Staerke = Staerke.Normal, gefuellt: Boolean = zeichen.gefuellt, beschreibung: String? = null) {
    val geviert = groesse * 1.2f
    val dichte = LocalDensity.current
    val opsz = geviert.value.toInt().coerceIn(20, 48)
    // In dp gerechnet, nicht in sp: ein Bedienzeichen waechst am iPhone mit einem festen Grad
    // nicht mit der Systemschrift, und hier soll es das auch nicht.
    val grad = with(dichte) { geviert.toSp() }
    val stil = TextStyle(fontFamily = schnitt(staerke.wght, gefuellt, opsz), fontSize = grad, color = farbe,
                         platformStyle = PlatformTextStyle(includeFontPadding = false))
    Layout(
        content = { BasicText(zeichen.text, style = stil, softWrap = false, maxLines = 1) },
        modifier = modifier.requiredSize(geviert)
            .then(if (zeichen.gespiegelt) Modifier.graphicsLayer { scaleX = -1f } else Modifier)
            .clearAndSetSemantics { if (beschreibung != null) contentDescription = beschreibung },
    ) { teile, grenzen ->
        val text = teile.first().measure(Constraints())
        val kante = grenzen.maxWidth
        val grundlinie = text[FirstBaseline].takeIf { it != AlignmentLine.Unspecified } ?: text.height
        layout(kante, grenzen.maxHeight) {
            // Mitte der Glyphe = Grundlinie minus halbes Geviert; die soll auf die Kastenmitte.
            text.place((kante - text.width) / 2, grenzen.maxHeight / 2 + kante / 2 - grundlinie)
        }
    }
}
