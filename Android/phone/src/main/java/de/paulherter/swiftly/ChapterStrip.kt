package de.paulherter.swiftly

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import org.json.JSONObject

/** One row of the core's chapter list (`Kern.chapterList`, the same rows as the Rust `ChaptersPart`). */
internal class ChapterEntry(val index: Int, val name: String?, val number: Int, val start: Double, val current: Boolean) {
    /** The server's own name, verbatim; only the numbered fallback ("Kapitel 3") is looked up in the catalog. */
    fun heading(numberTitle: String): String = name ?: translated(numberTitle, number.toLong())
    /** "m:ss", or "h:mm:ss" from one hour on. */
    val startText: String get() {
        val t = start.toLong()
        return if (t >= 3600) "%d:%02d:%02d".format(t / 3600, t % 3600 / 60, t % 60) else "%d:%02d".format(t / 60, t % 60)
    }
}

internal class ChapterList(val numberTitle: String, val rows: List<ChapterEntry>) {
    companion object { val none = ChapterList("Kapitel %lld", emptyList()) }
}

internal fun chapterListRead(json: String): ChapterList = runCatching {
    val o = JSONObject(json)
    val a = o.getJSONArray("kapitel")
    ChapterList(o.getString("nummerTitel"), List(a.length()) { i ->
        val c = a.getJSONObject(i)
        ChapterEntry(c.getInt("index"), if (c.isNull("name")) null else c.getString("name"), c.getInt("nummer"), c.getDouble("start"), c.getBoolean("jetzt"))
    })
}.getOrDefault(ChapterList.none)

/** The tab words of the Folgen panel; the core decides which tabs exist (series: Folgen + Kapitel, film: Kapitel only). */
internal enum class FolgenTab { Episodes, Chapters }

/** A word of the Folgen panel's tab row ("Folgen", "Kapitel"): white when open, quiet otherwise. */
@Composable
internal fun FolgenTabWord(label: String, on: Boolean, perform: () -> Unit) {
    Box(Modifier.height(32.dp).clip(RoundedCornerShape(16.dp)).pressRow(perform).padding(horizontal = 10.dp).semantics { selected = on },
        contentAlignment = Alignment.Center) {
        Text16(label, if (on) Theme.font else Theme.fontVeryQuiet, semibold = true, size = 15)
    }
}

/** The chapter tiles side by side in the Folgen layer, the running chapter brought near the middle. */
@Composable
internal fun ChapterStripRow(chapters: ChapterList, preview: (Double) -> Bitmap?, bottom: Dp, jump: (Double) -> Unit, modifier: Modifier = Modifier) {
    val state = rememberLazyListState(initialFirstVisibleItemIndex = (chapters.rows.indexOfFirst { it.current } - 1).coerceAtLeast(0))
    Box(modifier, contentAlignment = Alignment.Center) {
        LazyRow(state = state, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
                contentPadding = PaddingValues(bottom = bottom)) {
            items(chapters.rows, key = { it.index }) { c -> ChapterStripTile(c, chapters.numberTitle, preview(c.start)) { jump(c.start) } }
        }
    }
}

/** One chapter in the phone's strip: the trickplay picture at its start, "Name" and the start time; the running one larger. */
@Composable
internal fun ChapterStripTile(row: ChapterEntry, numberTitle: String, preview: Bitmap?, perform: () -> Unit) {
    val width = Theme.heroRowWidth
    val height = Theme.heroRowHeight
    val tileHeight = height + 8.dp + 16.dp + 2.dp + 15.dp
    val grow = if (row.current) 1.2f else 1f
    Box(Modifier.size(width * grow, tileHeight * grow).pressRow(perform).semantics { selected = row.current }) {
        Column(Modifier.requiredSize(width, tileHeight).graphicsLayer { scaleX = grow; scaleY = grow; transformOrigin = TransformOrigin(0f, 0f) },
               verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(width, height).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
                if (preview != null) Image(preview.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
            Column(Modifier.width(width), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(row.heading(numberTitle), style = Theme.tile, color = Theme.font, maxLines = 1, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.height(16.dp))
                Text(if (row.current) "${translated("Läuft")} · ${row.startText}" else row.startText, style = Theme.small, color = Theme.fontVeryQuiet,
                     maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.height(15.dp))
            }
        }
    }
}

/** One chapter on TV: the same tile as an episode (focus lift, caption under it), the picture drawn from the trickplay sheet. */
@Composable
internal fun TvChapterTile(row: ChapterEntry, numberTitle: String, preview: Bitmap?, modifier: Modifier = Modifier, perform: () -> Unit) {
    de.paulherter.swiftly.tv.TvTile(null, row.heading(numberTitle),
        if (row.current) "${translated("Läuft")} · ${row.startText}" else row.startText, landscape = true, modifier = modifier,
        substitute = preview?.let { b -> { Image(b.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) } },
        perform = perform)
}
