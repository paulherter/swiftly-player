package de.paulherter.swiftly

import androidx.media3.common.MimeTypes

/** Pure helpers for the sound codecs (`EngineChoiceTest`); the engine is always Media3. */
object EngineChoice {
    /**
     * Media3's MIME type for a Jellyfin audio codec name (`eac3`, `truehd` …), `null` if unknown. Jellyfin writes
     * the codec of the file lower case; DTS-HD and DTS:X come as `dts`, the profile is not part of the name.
     */
    fun audioMime(codec: String?): String? = when (codec?.lowercase()?.trim()) {
        "aac" -> MimeTypes.AUDIO_AAC
        "ac3" -> MimeTypes.AUDIO_AC3
        "eac3" -> MimeTypes.AUDIO_E_AC3
        "dts", "dca" -> MimeTypes.AUDIO_DTS
        "truehd", "mlp" -> MimeTypes.AUDIO_TRUEHD
        "flac" -> MimeTypes.AUDIO_FLAC
        "alac" -> MimeTypes.AUDIO_ALAC
        "opus" -> MimeTypes.AUDIO_OPUS
        "vorbis" -> MimeTypes.AUDIO_VORBIS
        "mp3" -> MimeTypes.AUDIO_MPEG
        "mp2" -> MimeTypes.AUDIO_MPEG_L2
        else -> if (codec?.startsWith("pcm_") == true) MimeTypes.AUDIO_RAW else null
    }
}
