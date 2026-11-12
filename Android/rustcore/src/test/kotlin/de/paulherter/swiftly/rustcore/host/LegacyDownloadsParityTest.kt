package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Old against new for the pure download rules: the Swift answers (Android/golden) against the core's. */
class LegacyDownloadsParityTest {
    private val golden = System.getenv("SWIFTLY_GOLDEN_DIR")

    private val list = """[{"id":"m1","konto":"a","art":"film","titel":"Film Eins","bytes":2000000000,"geladen":2000000000,"stand":"fertig","gesehen":true,"angelegt":750000000,"nochAufDemServer":true,"container":"mkv","laufzeitTicks":54000000000},{"id":"e1","konto":"a","art":"folge","titel":"Folge 1","serie":"Hafen","serienId":"s1","staffel":1,"folge":1,"bytes":500000000,"geladen":500000000,"stand":"fertig","gesehen":false,"angelegt":760000000,"nochAufDemServer":true,"qualitaet":"hd720","laufzeitTicks":27000000000},{"id":"e2","konto":"a","art":"folge","titel":"Folge 2","serie":"Hafen","serienId":"s1","staffel":1,"folge":2,"bytes":500000000,"geladen":100,"stand":"wartet","gesehen":false,"angelegt":760000001,"nochAufDemServer":true,"qualitaet":"hd720"},{"id":"m2","konto":"a","art":"film","titel":"Film Zwei","bytes":800000000,"geladen":300,"stand":"angehalten","gesehen":false,"angelegt":770000000,"nochAufDemServer":true}]"""
    private val same = """[{"id":"e1","konto":"a","art":"folge","titel":"Folge 1","bytes":5,"geladen":5,"stand":"fertig","gesehen":false,"angelegt":1,"nochAufDemServer":true,"qualitaet":"hd720"},{"id":"e2","konto":"a","art":"folge","titel":"Folge 2","bytes":5,"geladen":5,"stand":"fertig","gesehen":false,"angelegt":1,"nochAufDemServer":true,"qualitaet":"hd720"}]"""
    private val one = """{"id":"m2","konto":"a","art":"film","titel":"F","bytes":8,"geladen":8,"stand":"fertig","gesehen":false,"angelegt":1,"nochAufDemServer":true,"stelleTicks":600000000,"laufzeitTicks":54000000000}"""
    private val en = "en"

    @Test fun rules() {
        assumeTrue("no SWIFTLY_GOLDEN_DIR", golden != null)
        val cases = listOf(
            "dl-qualities" to legacyDownloadQualities(true, "[[2700000000,27000000000],[5,0]]", en),
            "dl-qualities-locked" to legacyDownloadQualities(false, "[]", en),
            "dl-qualities-low" to legacyDownloadQualities(true, "[[100000000,27000000000]]", en),
            "dl-estimated" to legacyDownloadEstimated("hd720", 2000000000, 54000000000).toString(),
            "dl-estimated-original" to legacyDownloadEstimated("original", 2000000000, 54000000000).toString(),
            "dl-estimated-noticks" to legacyDownloadEstimated("sd480", 2000000000, 0).toString(),
            "dl-badge-original" to legacyDownloadBadge("original", en),
            "dl-badge-720" to legacyDownloadBadge("hd720", en),
            "dl-quality-name" to legacyDownloadQualityName("hd1080", en),
            "dl-quality-name-original" to legacyDownloadQualityName("original", en),
            "dl-in-quality" to legacyDownloadInQuality(list, "sd480"),
            "dl-shared" to legacyDownloadShared(same, en),
            "dl-shared-mixed" to legacyDownloadShared(list, en),
            "dl-next" to legacyDownloadNext(list, true, true),
            "dl-next-cell" to legacyDownloadNext(list, false, true),
            "dl-may-load" to legacyDownloadMayLoad(false, true).toString(),
            "dl-may-load-yes" to legacyDownloadMayLoad(true, true).toString(),
            "dl-error-401" to legacyDownloadErrorText(401, en),
            "dl-error-404" to legacyDownloadErrorText(404, en),
            "dl-error-500" to legacyDownloadErrorText(500, en),
            "dl-space-fits" to legacyDownloadSpace(1000000000, 80000000000, list),
            "dl-space-tight" to legacyDownloadSpace(5000000000, 4000000000, list),
            "dl-groups" to legacyDownloadGroups(list),
            "dl-size" to legacyDownloadSize(18600000000, en),
            "dl-size-small" to legacyDownloadSize(112000, en),
            "dl-footer-free" to legacyDownloadFooterSpace(1000000000, 80000000000),
            "dl-footer-few" to legacyDownloadFooterSpace(5000000000, 1000000000),
            "dl-progress-gb" to legacyDownloadProgress(840000000, 2310000000, en),
            "dl-progress-mb" to legacyDownloadProgress(84000000, 231000000, en),
            "dl-progress-kb" to legacyDownloadProgress(840, 231000, en),
            "dl-progress-show-first" to legacyDownloadProgressShow(10, 1000, -1, -1.0).toString(),
            "dl-progress-show-fast" to legacyDownloadProgressShow(100, 1000, 50, 0.2).toString(),
            "dl-progress-show-slow" to legacyDownloadProgressShow(100, 1000, 50, 1.5).toString(),
            "dl-progress-show-end" to legacyDownloadProgressShow(1000, 1000, 990, 0.1).toString(),
            "dl-resume-from" to legacyDownloadResumeFrom(one).toString(),
            "dl-resume-from-none" to legacyDownloadResumeFrom("{}").toString(),
            "dl-next-episode" to legacyDownloadNextEpisode(list, en),
            "dl-next-episode-none" to legacyDownloadNextEpisode("[]", en),
            "dl-button-yes" to legacyDownloadButtonShow("1", true).toString(),
            "dl-button-forbidden" to legacyDownloadButtonShow("0", true).toString(),
            "dl-button-unknown" to legacyDownloadButtonShow("", true).toString(),
            "dl-button-off" to legacyDownloadButtonShow("1", false).toString(),
        )
        val failures = cases.mapNotNull { (name, new) ->
            File("/tmp/andscr-new-$name.json").writeText(new)
            val old = File(golden!!, "$name.json").readText()
            val diff = if (old.trimStart().startsWith("{") || old.trimStart().startsWith("[")) JsonParity.diff(old, new)
                       else if (old == new) null
                       else if (old.toDoubleOrNull() != null && new.toDoubleOrNull() != null && Math.abs(old.toDouble() - new.toDouble()) < 1e-6) null
                       else "text old '$old' new '$new'"
            diff?.let { "$name: $it" }
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun estimatorFollowsReportsAndForgets() {
        legacyDownloadEstimatorReport("x1", 1000, 10000)
        val v = legacyDownloadEstimatorValue("x1", 5)
        assertTrue("estimate $v", v >= 1000)
        legacyDownloadEstimatorHalt("x1")
        legacyDownloadEstimatorForget("x1")
        assertEquals(77L, legacyDownloadEstimatorValue("x1", 77))
    }
}
