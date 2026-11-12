package de.paulherter.swiftly

import android.app.Instrumentation
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.URL
import java.util.concurrent.atomic.AtomicReference

/**
 * **Subtitle contract on Android, phone and TV, through the real player path**
 * (`PlayerEngine`: Media3, `CaptionLayer`), against `cargo xtask fixture-server` media.
 *
 * Needs `-e fixture http://10.0.2.2:<port>` (the fixture server started with `SWIFTLY_FIXTURE_MEDIA_DIR` pointing at
 * `Werkzeuge/pruefstand-medien.py` output). Without it the player tests are skipped. Proof pictures land in
 * `getExternalFilesDir("subtitle-proof")` (`adb pull`). Run: `Werkzeuge/subtitles-android.sh <emulator-serial>`.
 */
@RunWith(AndroidJUnit4::class)
class SubtitleContractTest {
    private val inst: Instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Context = inst.targetContext
    private val fixture: String? = InstrumentationRegistry.getArguments().getString("fixture")
    private val isTv: Boolean get() = (app.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType ==
        Configuration.UI_MODE_TYPE_TELEVISION
    private val device get() = if (isTv) "tv" else "phone"
    private val proof: File = (app.getExternalFilesDir("subtitle-proof") ?: app.filesDir).also { it.mkdirs() }
    private var engine: PlayerEngine? = null
    private var activity: ProbeActivity? = null

    @After fun down() {
        inst.runOnMainSync { engine?.media3Down() }
        activity?.finish()
    }

    // ---- helpers

    private fun get(path: String): String = URL(fixture + path).openStream().use { String(it.readBytes()) }

    /** Jellyfin index + address of the external subtitle files of a bench title. */
    private fun externals(id: String): List<Pair<Long, String>> {
        val streams = JSONObject(get("/Items/$id/PlaybackInfo")).getJSONArray("MediaSources").getJSONObject(0).getJSONArray("MediaStreams")
        return (0 until streams.length()).map { streams.getJSONObject(it) }.filter { it.optBoolean("IsExternal") }
            .map { it.getLong("Index") to fixture + it.getString("DeliveryUrl") }
    }

    private fun <T> main(block: () -> T): T {
        val out = AtomicReference<T>()
        inst.runOnMainSync { out.set(block()) }
        return out.get()
    }

    private fun waitFor(what: String, ms: Long = 20_000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { if (cond()) return; Thread.sleep(50) }
        throw AssertionError("timed out waiting for $what [cue='${engine?.cueText}' time=${engine?.let { main { it.time } }} playing=${engine?.isPlaying}]")
    }

    private fun start(id: String, look: String = "", since: Double = 0.0, withExternals: Boolean = true, play: Boolean = false): PlayerEngine {
        val i = Intent(app, ProbeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val a = inst.startActivitySync(i) as ProbeActivity
        activity = a
        val subs = if (withExternals) externals(id) else emptyList()
        val e = main { PlayerEngine(app, isTv, look) }
        engine = e
        inst.runOnMainSync {
            e.media3Configure("auto", false)
            e.attach(a.host)
            e.openMedia3("$fixture/Videos/$id/stream", since, subs)
            if (play) e.play() else e.pause()
        }
        return e
    }

    /** Waits for the tracks, picks the `n`-th text track, returns its name. */
    private fun pick(e: PlayerEngine, n: Int): String {
        waitFor("text tracks") { main { e.spuTracks?.size ?: 0 } > n }
        val t = main { e.spuTracks!! }[n]
        e.spuTrack = t.id
        return t.name.orEmpty()
    }

    private fun seek(e: PlayerEngine, ms: Long) { main { e.time = ms } }

    private fun shot(): Bitmap = inst.uiAutomation.takeScreenshot()

    private fun save(b: Bitmap, name: String) { File(proof, "$device-$name.png").outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) } }

    /** Pixels that differ clearly between two screenshots, in the lower 40 % where the subtitle sits. */
    private fun changed(a: Bitmap, b: Bitmap): Int {
        var n = 0
        for (y in (a.height * 0.6).toInt() until a.height step 2) for (x in 0 until a.width step 2) {
            val p = a.getPixel(x, y); val q = b.getPixel(x, y)
            if (Math.abs(Color.red(p) - Color.red(q)) + Math.abs(Color.green(p) - Color.green(q)) + Math.abs(Color.blue(p) - Color.blue(q)) > 120) n++
        }
        return n
    }

    /**
     * One title, one text track: it must show `expected` at `at` ms (Media3's cue output), be on the screenshot (a
     * paused frame with and without the subtitle differs where the text sits), and go off again.
     */
    private fun showsAndHides(id: String, track: Int, expected: String, at: Long, name: String, withExternals: Boolean = true) {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start(id, withExternals = withExternals)
        val title = pick(e, track)
        Log.i(TAG, "$device $name track='$title'")
        waitFor("first frame") { main { e.length } > 0 }
        seek(e, at)
        waitFor("cue '$expected' (got '${e.cueText}')") { e.cueText.contains(expected) }
        Thread.sleep(600)
        val on = shot()
        save(on, name)
        e.spuTrack = -1
        waitFor("cue gone") { e.cueText.isEmpty() }
        Thread.sleep(600)
        val off = shot()
        val diff = changed(on, off)
        Log.i(TAG, "$device $name changedPixels=$diff")
        assertTrue("$name: the subtitle is not on the screenshot (diff $diff)", diff > 400)
    }

    // ---- line 1: embedded text in MKV and MP4

    @Test fun line1_embeddedSrtInMkv() = showsAndHides("bm-multi-mkv", 0, "Bench cue one", 1500, "embedded-srt-mkv", withExternals = false)
    @Test fun line1_embeddedTextInMp4() = showsAndHides("bm-mp4-text", 0, "Bench cue one", 1500, "embedded-text-mp4", withExternals = false)

    // ---- line 2: external files

    @Test fun line2_externalSrt() = showsAndHides("bm-ext-subs", 0, "Bench cue one", 1500, "external-srt")
    @Test fun line2_externalAss() = showsAndHides("bm-ext-subs", 1, "Bench ass one", 1500, "external-ass")
    @Test fun line2_externalVtt() = showsAndHides("bm-ext-vtt", 0, "Bench vtt one", 1500, "external-vtt")

    // ---- line 3: embedded ASS in MKV (the second embedded track of bm-multi-mkv)

    @Test fun line3_embeddedAssInMkv() = showsAndHides("bm-multi-mkv", 1, "Bench ass one", 1500, "embedded-ass-mkv", withExternals = false)

    /** Line 3: "Stil der Datei verwenden" on takes the file's yellow, off draws the plain text in the saved (white) look. */
    @Test fun line3_fileStyleSwitch() {
        assumeTrue("needs -e fixture", fixture != null)
        val on = KernRules.subtitleLookChange("", "keepFileStyle", "true")
        val off = KernRules.subtitleLookChange("", "keepFileStyle", "false")
        fun yellowPixels(look: String): Int {
            val e = start("bm-ass-styled", look)
            pick(e, 0)
            waitFor("first frame") { main { e.length } > 0 }
            seek(e, 1500)
            waitFor("cue") { e.cueText.contains("Bench ass one") }
            val b = main { e.captionLayer!!.text.renderOn(Color.rgb(128, 128, 128), 1920, 1080) }
            var n = 0
            for (y in 0 until b.height step 2) for (x in 0 until b.width step 2) {
                val p = b.getPixel(x, y)
                if (Color.red(p) >= 230 && Color.green(p) >= 230 && Color.blue(p) < 120) n++
            }
            if (look == on) save(b, "file-style-on")
            down()
            return n
        }
        val keep = yellowPixels(on)
        val plain = yellowPixels(off)
        Log.i(TAG, "$device fileStyle yellowPixels on=$keep off=$plain")
        assertTrue("with the switch on the file's yellow must show ($keep)", keep > 50)
        assertEquals("with the switch off the saved look applies, no file colour", 0, plain)
    }

    // ---- line 4: bitmap subtitles (PGS) after a resume deep into the file

    @Test fun line4_pgsAfterResume() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-pgs-mkv", since = 120.0, withExternals = false)
        waitFor("text tracks") { main { e.spuTracks?.size ?: 0 } >= 2 }
        val names = main { e.spuTracks!! }
        val pgs = names.firstOrNull { it.name.orEmpty().contains("Forced", true) || it.name.orEmpty().contains("pgs", true) } ?: names[0]
        e.spuTrack = pgs.id
        main { e.play() }
        waitFor("a picture cue after the resume", 60_000) { e.cueBitmaps > 0 }
        Thread.sleep(400)
        val on = shot()
        save(on, "pgs-after-resume")
        Log.i(TAG, "$device pgs track='${pgs.name}' bitmaps=${e.cueBitmaps}")
        assertTrue(e.cueBitmaps > 0)
    }

    private fun pickPgs(e: PlayerEngine) {
        waitFor("text tracks") { main { e.spuTracks?.size ?: 0 } >= 2 }
        val names = main { e.spuTracks!! }
        val pgs = names.firstOrNull { it.name.orEmpty().contains("Forced", true) || it.name.orEmpty().contains("pgs", true) } ?: names[0]
        e.spuTrack = pgs.id
    }

    /**
     * Line 4 / 14: a far paused jump into a picture cue. `bm-pgs-mkv` shows its display set from 124 s to 126 s; Media3 starts
     * reading at the keyframe at 125 s and never sees the set that began at 124 s, so only a pre-roll (read from a little
     * earlier, land at 125 s exactly) can draw it. The film stays paused and ends up at 125 s, not at the pre-roll start.
     */
    @Test fun line14_pgsPausedFarSeekIntoCue() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-pgs-mkv", withExternals = false)
        pickPgs(e)
        waitFor("first frame") { main { e.length } > 0 }
        Thread.sleep(500)
        seek(e, 125_000)
        waitFor("a picture cue after a paused jump to 125 s (bitmaps=${e.cueBitmaps})", 20_000) { e.cueBitmaps > 0 }
        Thread.sleep(600)
        val at = main { e.time }
        save(shot(), "pgs-far-seek")
        Log.i(TAG, "$device pgs far seek bitmaps=${e.cueBitmaps} time=$at")
        assertTrue("landed at $at ms, not at 125 s", at in 124_900..126_000)
        assertTrue("still paused", !main { e.isPlaying })
    }

    /** Resume at 125 s (inside the cue) with the picture track chosen: the cue is on the paused first frame. */
    @Test fun line4_pgsResumeInsideCue() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-pgs-mkv", since = 125.0, withExternals = false)
        pickPgs(e)
        waitFor("a picture cue at the resume point (bitmaps=${e.cueBitmaps})", 25_000) { e.cueBitmaps > 0 }
        val at = main { e.time }
        Log.i(TAG, "$device pgs resume at 125 s bitmaps=${e.cueBitmaps} time=$at")
        assertTrue("resumed at $at ms", at in 124_900..126_000)
    }

    // ---- line 12/13: list and switching

    @Test fun line12_listShowsEachTrackOnce() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-ext-subs")
        waitFor("tracks") { main { e.spuTracks?.size ?: 0 } >= 2 }
        Thread.sleep(500)
        val tracks = main { e.spuTracks!! }
        assertEquals("external SRT + ASS, each once: $tracks", 2, tracks.size)
        val files = main { e.trackDetails().values.mapNotNull { it.file } }
        assertEquals("every file track maps back to its index once", files.toSet().size, files.size)
        down()
        val m = start("bm-multi-mkv", withExternals = false)
        waitFor("tracks") { main { m.spuTracks?.size ?: 0 } >= 2 }
        Thread.sleep(500)
        assertEquals("embedded SRT + ASS, each once", 2, main { m.spuTracks!!.size })
    }

    @Test fun line13_chooseSwitchOffOn() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-ext-subs")
        pick(e, 0)
        waitFor("first frame") { main { e.length } > 0 }
        seek(e, 1500)
        waitFor("srt cue") { e.cueText.contains("Bench cue one") }
        pick(e, 1)
        waitFor("switch to ass") { e.cueText.contains("Bench ass one") }
        e.spuTrack = -1
        waitFor("off") { e.cueText.isEmpty() }
        assertEquals(-1, main { e.spuTrack })
        pick(e, 0)
        waitFor("on again") { e.cueText.contains("Bench cue one") }
    }

    // ---- line 14: timing

    @Test fun line14_seekPauseResumeSpeedDelay() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-ext-subs")
        pick(e, 0)
        waitFor("first frame") { main { e.length } > 0 }
        seek(e, 7500); waitFor("cue three after a seek") { e.cueText.contains("Bench cue three") }
        seek(e, 4500); waitFor("cue two after a seek") { e.cueText.contains("Bench cue two") }
        seek(e, 6500); waitFor("cue two after a seek back") { e.cueText.contains("Bench cue two") }
        // Resume: runs on and the cue leaves at 6 s.
        seek(e, 5200); waitFor("cue two") { e.cueText.contains("Bench cue two") }
        main { e.play() }
        waitFor("cue gone after resume", 5000) { e.cueText.isEmpty() }
        main { e.pause() }
        // Pause keeps the cue.
        seek(e, 4500); waitFor("cue two paused") { e.cueText.contains("Bench cue two") }
        Thread.sleep(800)
        assertTrue("paused cue stays", e.cueText.contains("Bench cue two"))
        // Speed 2x: from 4.5 s the cue is gone after about 0.8 s of wall time, not 1.5 s.
        main { e.rateSet(2f); e.play() }
        val t0 = System.currentTimeMillis()
        waitFor("cue gone at 2x", 3000) { e.cueText.isEmpty() }
        val took = System.currentTimeMillis() - t0
        Log.i(TAG, "$device speed 2x cue left after ${took}ms")
        assertTrue("2x did not speed the cues up ($took ms)", took < 1400)
        main { e.rateSet(1f); e.pause() }
        // Delay +2 s: cue one (1-3 s) shows at 2 s no more, at 4 s yes.
        main { e.delaysMedia3Set(0, 2000) }
        seek(e, 1500); Thread.sleep(700)
        assertTrue("delayed cue shows too early: '${e.cueText}'", !e.cueText.contains("Bench cue one"))
        seek(e, 3500); waitFor("delayed cue one at 3.5 s") { e.cueText.contains("Bench cue one") }
    }

    /** Line 14: a forward seek out of a cue into the next one, paused, shows the next cue (was flaky: left the text empty). */
    @Test fun line14_seekForwardIntoNextCuePaused() {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-ext-subs")
        pick(e, 0)
        waitFor("first frame") { main { e.length } > 0 }
        seek(e, 4500); waitFor("cue two") { e.cueText.contains("Bench cue two") }
        seek(e, 7500); waitFor("cue three after the forward seek") { e.cueText.contains("Bench cue three") }
    }

    /**
     * Line 14 for embedded tracks, the way the live runner meets it: the film plays past the cue (1-3 s) with the track
     * still off, the track is switched on at about 4 s, and a paused jump back to 2 s must show the cue at once. Media3
     * re-reads Matroska text from the seek point on and never sees the cue that began at 1 s, so only the app's cue table
     * (fed through the extractor's parser factory) can draw it.
     */
    private fun embeddedPausedSeekBack(track: Int, expected: String) {
        assumeTrue("needs -e fixture", fixture != null)
        val e = start("bm-multi-mkv", withExternals = false, play = true)
        waitFor("tracks") { main { e.spuTracks?.size ?: 0 } > track }
        waitFor("position past 4 s", 30_000) { main { e.time } > 4000 }
        pick(e, track)
        inst.runOnMainSync { e.pause() }
        Thread.sleep(700)
        seek(e, 2000)
        waitFor("cue '$expected' after a paused jump back to 2 s (got '${e.cueText}')", 6_000) { e.cueText.contains(expected) }
    }
    @Test fun line14_embeddedSrtPausedSeekIntoCue() = embeddedPausedSeekBack(0, "Bench cue one")
    @Test fun line14_embeddedAssPausedSeekIntoCue() = embeddedPausedSeekBack(1, "Bench ass one")

    // ---- line 8/9/10: the look against the Apple reference

    private fun reference(name: String): JSONObject =
        JSONObject(InstrumentationRegistry.getInstrumentation().context.assets.open("subtitle-reference.json").use { String(it.readBytes()) }).getJSONObject(name)

    /** Area metrics of `subtitle-measure.py`, in percent of the font size (areas of its square). */
    private fun measure(b: Bitmap, fontPx: Double): DoubleArray {
        var fill = 0; var dark = 0
        var x0 = b.width; var y0 = b.height; var x1 = 0; var y1 = 0
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        for (y in 0 until b.height) for (x in 0 until b.width) {
            val p = px[y * b.width + x]
            val lum = 0.299 * Color.red(p) + 0.587 * Color.green(p) + 0.114 * Color.blue(p)
            val f = lum >= 200; val d = lum <= 60
            if (f || d) {
                if (f) fill++ else dark++
                if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y
            }
        }
        val sq = fontPx * fontPx
        return doubleArrayOf(100 * fill / sq, 100 * dark / sq, 100 * (x1 - x0 + 1) / fontPx, 100 * (y1 - y0 + 1) / fontPx)
    }

    /** The sentence as the player draws it for `look` (picture 1920 x 1080, base scale 0.78 like the Apple render). */
    private fun draw(look: String, line: CharSequence = "Switch off: the saved look only"): Pair<Bitmap, Double> {
        val facts = JSONObject(KernRules.subtitleLookFacts(look, 0.78))
        val layer = main { CaptionLayer(app).also { it.apply(facts); it.text.setCues(listOf(line)) } }
        val bmp = main { layer.text.renderOn(Color.rgb(128, 128, 128), 1920, 1080) }
        return bmp to 1080 * facts.getDouble("fraction")
    }

    private fun checkLook(name: String, look: String, compareOutline: Boolean = true) {
        val (bmp, px) = draw(look)
        save(bmp, "look-$name")
        val m = measure(bmp, px)
        val r = reference(name)
        Log.i(TAG, "$device look $name android fill=${m[0].toInt()} outline=${m[1].toInt()} width=${m[2].toInt()} height=${m[3].toInt()} | ios fill=${r.getDouble("fill").toInt()} outline=${r.getDouble("outline").toInt()} width=${r.getDouble("width").toInt()} height=${r.getDouble("height").toInt()}")
        fun near(what: String, got: Double, want: Double, tol: Double) =
            assertTrue("$name $what: Android ${got.toInt()} vs iOS ${want.toInt()} (tolerance ${(tol * 100).toInt()} %)", Math.abs(got - want) <= want * tol)
        near("fill (weight)", m[0], r.getDouble("fill"), 0.15)
        near("width (typeface)", m[2], r.getDouble("width"), 0.06)
        near("height", m[3], r.getDouble("height"), 0.12)
        if (compareOutline) near("outline (ratio)", m[1], r.getDouble("outline"), 0.2)
    }


    /**
     * The red state this contract line started from: Media3's own `SubtitleView` (what the player used before
     * `CaptionLayer`) with the same look draws the outline at a fixed 2 dp and in the system typeface, so it is outside
     * the Apple reference. Kept as a characterisation: if it ever matched, the new view would have no reason to exist.
     */
    @Test fun line8_wasRed_media3ViewMissesTheAppleLook() {
        val facts = JSONObject(KernRules.subtitleLookFacts("", 0.78))
        val view = main {
            androidx.media3.ui.SubtitleView(app).apply {
                setStyle(androidx.media3.ui.CaptionStyleCompat(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT,
                    androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, null))
                setFractionalTextSize(facts.getDouble("fraction").toFloat())
                setBottomPaddingFraction(0.08f)
                setCues(listOf(androidx.media3.common.text.Cue.Builder().setText("Switch off: the saved look only").build()))
                measure(android.view.View.MeasureSpec.makeMeasureSpec(1920, android.view.View.MeasureSpec.EXACTLY),
                    android.view.View.MeasureSpec.makeMeasureSpec(1080, android.view.View.MeasureSpec.EXACTLY))
                layout(0, 0, 1920, 1080)
            }
        }
        val bmp = Bitmap.createBitmap(1920, 1080, Bitmap.Config.ARGB_8888)
        main { val c = android.graphics.Canvas(bmp); c.drawColor(Color.rgb(128, 128, 128)); view.draw(c) }
        val m = measure(bmp, 1080 * facts.getDouble("fraction"))
        val r = reference("standard")
        Log.i(TAG, "$device old media3 view fill=${m[0].toInt()} outline=${m[1].toInt()} width=${m[2].toInt()} | ios fill=${r.getDouble("fill").toInt()} outline=${r.getDouble("outline").toInt()} width=${r.getDouble("width").toInt()}")
        val ok = Math.abs(m[0] - r.getDouble("fill")) <= r.getDouble("fill") * 0.15 &&
            Math.abs(m[1] - r.getDouble("outline")) <= r.getDouble("outline") * 0.2 &&
            Math.abs(m[2] - r.getDouble("width")) <= r.getDouble("width") * 0.06
        assertTrue("Media3's own view would match the Apple look; the contract line was not red", !ok)
    }


    @Test fun line9_defaultLook() = checkLook("standard", "")

    /** "the saved look": large, yellow, thin outline. */
    /** Line 8a: the text's lowest ink sits about 16 dp above the picture's bottom edge; "raised" lifts it by 7 % of the picture height. */
    @Test fun line8a_bottomMarginIsSixteenDpAndRaisedAddsSevenPercent() {
        val density = app.resources.displayMetrics.density
        fun gap(look: String): Pair<Int, Double> {
            val (bmp, px) = draw(look, "Margin test")
            var lowest = -1
            val row = IntArray(bmp.width)
            for (y in bmp.height - 1 downTo 0) {
                bmp.getPixels(row, 0, bmp.width, 0, y, bmp.width, 1)
                if (row.any { Color.red(it) != 128 }) { lowest = y; break }
            }
            return (bmp.height - 1 - lowest) to px
        }
        val (flat, font) = gap("")
        val (raised, _) = gap(KernRules.subtitleLookChange("", "position", "raised"))
        Log.i(TAG, "$device bottom gap flat=$flat raised=$raised dp16=${16 * density} font=${font.toInt()}")
        // The ink ends above the line box (descender room), so allow up to a third of the font size on top of 16 dp.
        assertTrue("flat gap $flat px, expected 16 dp = ${16 * density} px (+ descender room)", flat >= 16 * density - 2 && flat <= 16 * density + font / 3)
        assertEquals("raised lifts by 7 % of 1080", 0.07 * 1080, (raised - flat).toDouble(), 3.0)
    }

    @Test fun line8_pauls_look() {
        var look = KernRules.subtitleLookChange("", "size", "large")
        look = KernRules.subtitleLookChange(look, "colour", "yellow")
        look = KernRules.subtitleLookChange(look, "outline", "thin")
        checkLook("paul", look)
    }

    @Test fun line8_shadowAndBackground() {
        var look = KernRules.subtitleLookChange("", "size", "small")
        look = KernRules.subtitleLookChange(look, "outline", "off")
        look = KernRules.subtitleLookChange(look, "shadow", "true")
        look = KernRules.subtitleLookChange(look, "background", "true")
        checkLook("shadowBox", look, compareOutline = false)
    }

    /** Line 10: Arabic stays readable (the outline sits behind the fill and never eats it); Latin is the standard test. */
    @Test fun line10_arabicReadable() {
        val arabic = "لا يمكنك الهروب من الماضي، مهما حاولت"
        val (withOutline, px) = draw("", arabic)
        val (noOutline, _) = draw(KernRules.subtitleLookChange("", "outline", "off"), arabic)
        save(withOutline, "look-arabic")
        val a = measure(withOutline, px)
        val b = measure(noOutline, px)
        Log.i(TAG, "$device arabic fill with outline=${a[0].toInt()} without=${b[0].toInt()} outline=${a[1].toInt()} ios fill=${reference("arabic").getDouble("fill").toInt()}")
        assertTrue("the outline eats the Arabic letters (${a[0]} < ${b[0]})", a[0] >= b[0] * 0.88)
        assertTrue("no outline drawn", a[1] > 0)
    }

    /** Line 10: Devanagari and Thai draw real glyphs (no tofu boxes), the outline stays behind the fill. */
    private fun scriptReadable(name: String, line: String) {
        val paint = android.graphics.Paint()
        val missing = line.codePoints().toArray().filter { !Character.isWhitespace(it) && !paint.hasGlyph(String(Character.toChars(it))) }
        assertTrue("$name: no glyph for ${missing.joinToString { Integer.toHexString(it) }} (tofu)", missing.isEmpty())
        val (withOutline, px) = draw("", line)
        val (noOutline, _) = draw(KernRules.subtitleLookChange("", "outline", "off"), line)
        save(withOutline, "look-$name")
        val a = measure(withOutline, px)
        val b = measure(noOutline, px)
        Log.i(TAG, "$device $name fill with outline=${a[0].toInt()} without=${b[0].toInt()} outline=${a[1].toInt()}")
        assertTrue("$name: nothing drawn", b[0] > 0)
        assertTrue("the outline eats the $name letters (${a[0]} < ${b[0]})", a[0] >= b[0] * 0.88)
        assertTrue("$name: no outline drawn", a[1] > 0)
        // Tofu would draw the same box for every letter: two different lines must not render alike.
        val (other, _) = draw("", line.reversed())
        assertTrue("$name: different text renders the same picture (tofu)", !withOutline.sameAs(other))
    }

    @Test fun line10_devanagariReadable() = scriptReadable("devanagari", "आप अपने अतीत से भाग नहीं सकते, चाहे कितनी भी कोशिश करें")

    @Test fun line10_thaiReadable() = scriptReadable("thai", "คุณหนีจากอดีตไม่ได้ ไม่ว่าจะพยายามแค่ไหน")

    // ---- line 11: a look that arrives from another device

    @Test fun line11_syncedLookIsAppliedAndFollowedLive() {
        val application = app.applicationContext as SwiftlyApplication
        val before = application.settings.subtitleLook
        try {
            val yellow = KernRules.subtitleLookChange("", "colour", "yellow")
            // The sync step writes the look into the settings (`applySynced`), which a player created later reads at once.
            inst.runOnMainSync { application.settings.applySynced(mapOf("utAussehen" to yellow)) }
            assertEquals(KernRules.subtitleLookNormalise(yellow), application.settings.subtitleLook)
            val layerNow = { JSONObject(KernRules.subtitleLookFacts(application.settings.subtitleLook, 0.78)).getInt("rgb") }
            assertEquals(0xFFE45C, layerNow())
            // A running player: the settings change (a second sync) and the player's look follows without a restart.
            val a = start("bm-multi-mkv", look = application.settings.subtitleLook, withExternals = false)
            pick(a, 0)
            waitFor("first frame") { main { a.length } > 0 }
            seek(a, 1500)
            waitFor("cue") { a.cueText.contains("Bench cue one") }
            fun fillColour(): Int {
                val b = main { a.captionLayer!!.text.renderOn(Color.rgb(128, 128, 128), 1920, 1080) }
                var r = 0L; var g = 0L; var bl = 0L; var n = 0L
                for (y in 0 until b.height step 2) for (x in 0 until b.width step 2) {
                    val p = b.getPixel(x, y)
                    if (Color.red(p) >= 230 && Color.green(p) >= 200) { r += Color.red(p); g += Color.green(p); bl += Color.blue(p); n++ }
                }
                return if (n == 0L) 0 else Color.rgb((r / n).toInt(), (g / n).toInt(), (bl / n).toInt())
            }
            val first = fillColour()
            assertTrue("yellow expected before the change: ${Integer.toHexString(first)}", Color.blue(first) < 140 && first != 0)
            val white = KernRules.subtitleLookChange("", "colour", "white")
            // The collector the player page starts (`followLook`), not a manual call.
            val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main)
            val job = main { a.followLook(application.settings, scope) }
            Thread.sleep(300)
            inst.runOnMainSync { application.settings.applySynced(mapOf("utAussehen" to white)); androidx.compose.runtime.snapshots.Snapshot.sendApplyNotifications() }
            Thread.sleep(500)
            job.cancel()
            val second = fillColour()
            assertTrue("white expected after the change: ${Integer.toHexString(second)}", Color.blue(second) > 200)
        } finally {
            inst.runOnMainSync { application.settings.applySynced(mapOf("utAussehen" to before.ifEmpty { KernRules.subtitleLookStandard() })) }
        }
    }

    private companion object { const val TAG = "SubtitleContract" }
}
