package de.paulherter.swiftly

import androidx.media3.common.MimeTypes
import de.paulherter.swiftly.EngineChoice.Engine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The choice between VLC and Media3 as a pure rule: no device needed. */
class EngineChoiceTest {

    private fun decide(setting: String = "dolbyVision", software: Boolean = false, failed: Boolean = false,
                       dv: Int? = 8, device: Boolean = true, audio: Boolean = true) =
        EngineChoice.decide(setting, software, failed, dv, device, audio)

    @Test fun dolbyVisionFileOnCapableDeviceGoesToMedia3() {
        assertEquals(Engine.MEDIA3, decide())
        // The profile 0 (unknown) counts as Dolby Vision as well.
        assertEquals(Engine.MEDIA3, decide(dv = 0))
    }

    @Test fun otherFilesStayWithVlcInTheDefaultSetting() {
        assertEquals(Engine.VLC, decide(dv = null))
    }

    @Test fun deviceWithoutDolbyVisionStaysWithVlc() {
        assertEquals(Engine.VLC, decide(device = false))
    }

    @Test fun soundTheDeviceCannotPlayKeepsVlc() {
        // TrueHD or DTS without a decoder: Media3 would play silent.
        assertEquals(Engine.VLC, decide(audio = false))
        assertEquals(Engine.VLC, decide(setting = "exoplayer", audio = false))
    }

    @Test fun failedMedia3NeverComesBack() {
        // After an error before and after the first frame alike: no loop between the engines.
        assertEquals(Engine.VLC, decide(failed = true))
        assertEquals(Engine.VLC, decide(setting = "exoplayer", failed = true))
    }

    @Test fun softwareDecoderStaysWithVlc() {
        assertEquals(Engine.VLC, decide(software = true))
        assertEquals(Engine.VLC, decide(setting = "exoplayer", software = true))
    }

    @Test fun alwaysExoPlayerTakesEverythingItCanPlay() {
        assertEquals(Engine.MEDIA3, decide(setting = "exoplayer", dv = null, device = false))
    }

    @Test fun alwaysVlcIsAlwaysVlc() {
        assertEquals(Engine.VLC, decide(setting = "vlc"))
    }

    @Test fun unknownSettingCountsAsDefault() {
        assertEquals(Engine.MEDIA3, decide(setting = "irgendwas"))
        assertEquals(Engine.VLC, decide(setting = "irgendwas", dv = null))
    }

    @Test fun audioCodecNamesMapToMediaTypes() {
        assertEquals(MimeTypes.AUDIO_E_AC3, EngineChoice.audioMime("eac3"))
        assertEquals(MimeTypes.AUDIO_E_AC3, EngineChoice.audioMime(" EAC3 "))
        assertEquals(MimeTypes.AUDIO_TRUEHD, EngineChoice.audioMime("truehd"))
        assertEquals(MimeTypes.AUDIO_DTS, EngineChoice.audioMime("dts"))
        assertEquals(MimeTypes.AUDIO_RAW, EngineChoice.audioMime("pcm_s16le"))
        assertNull(EngineChoice.audioMime("wmapro"))
        assertNull(EngineChoice.audioMime(null))
    }

    @Test fun reasonNamesTheFirstRuleThatApplies() {
        assertEquals("Software-Dekoder", EngineChoice.reasonVlc("dolbyVision", true, true, false))
        assertEquals("Media3 gescheitert", EngineChoice.reasonVlc("dolbyVision", false, true, false))
        assertEquals("Ton ohne Dekoder-Erweiterung nicht spielbar", EngineChoice.reasonVlc("vlc", false, false, false))
        assertEquals("Einstellung VLC", EngineChoice.reasonVlc("vlc", false, false, true))
        assertEquals("Gerät ohne DV", EngineChoice.reasonVlc("dolbyVision", false, false, true))
    }
}
