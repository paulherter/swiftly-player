package de.paulherter.swiftly

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The sound codec names as Media3 MIME types: no device needed. */
class EngineChoiceTest {
    @Test fun jellyfinNamesMapToMedia3Types() {
        assertEquals(MimeTypes.AUDIO_AC3, EngineChoice.audioMime("ac3"))
        assertEquals(MimeTypes.AUDIO_E_AC3, EngineChoice.audioMime("EAC3"))
        assertEquals(MimeTypes.AUDIO_TRUEHD, EngineChoice.audioMime("truehd"))
        assertEquals(MimeTypes.AUDIO_TRUEHD, EngineChoice.audioMime("mlp"))
        assertEquals(MimeTypes.AUDIO_DTS, EngineChoice.audioMime("dts"))
        assertEquals(MimeTypes.AUDIO_RAW, EngineChoice.audioMime("pcm_s16le"))
    }

    @Test fun unknownCodecHasNoType() {
        assertNull(EngineChoice.audioMime("wmapro"))
        assertNull(EngineChoice.audioMime(null))
    }
}
