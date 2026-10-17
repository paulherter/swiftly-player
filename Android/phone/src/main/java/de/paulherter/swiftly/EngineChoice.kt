package de.paulherter.swiftly

import androidx.media3.common.MimeTypes

/**
 * **Which engine opens a title: VLC or Media3 (ExoPlayer)?** A pure function, so the rule can be tested
 * without a device (`EngineChoiceTest`).
 *
 * Media3 comes in only where libVLC 3 cannot do the job: Dolby Vision. Everything else stays with VLC, and so
 * does Direct Play. **Media3 here has no FFmpeg decoder extension** (the Jellyfin build of it,
 * `org.jellyfin.media3:media3-ffmpeg-decoder`, is published under the GPL-3.0 and Swiftly is MPL-2.0 with an
 * LGPL player), so it plays only what the device decodes or passes through itself. Media3 drops a track it cannot play without an error, and the title would be
 * silent. That is why Media3 is chosen only if **picture and sound** are both within its reach:
 *
 * - picture: not for a title that needs the software decoder; a codec Media3 cannot show makes it fail
 *   before the first frame, and then VLC takes over (`PlayItem.media3GiveUp`);
 * - sound: the default audio track must be decodable by the device's MediaCodec or pass through
 *   (`audioPlayable`, asked of the device in `PlayerEngine.audioPlayable`); TrueHD and DTS usually fall to
 *   VLC.
 */
object EngineChoice {
    enum class Engine { VLC, MEDIA3 }

    const val DOLBY_VISION = "dolbyVision"
    const val EXOPLAYER = "exoplayer"
    const val VLC = "vlc"

    /**
     * @param setting `dolbyVision` (default), `exoplayer` or `vlc` (`Settings.playerEngine`); anything else counts as the default.
     * @param softwareDecoder the title needs the software decoder (rescue stage or MPEG-4 Part 2): VLC.
     * @param media3Failed Media3 has already failed for this title: VLC, for good.
     * @param dolbyVision Dolby Vision profile of the unchanged file, `null` without Dolby Vision or when converting.
     * @param deviceDolbyVision the device has a Dolby Vision decoder and a display that reports it.
     * @param audioPlayable the default audio track can be decoded or passed through without a decoder extension
     *   (true for a file without sound).
     */
    fun decide(setting: String, softwareDecoder: Boolean, media3Failed: Boolean, dolbyVision: Int?,
               deviceDolbyVision: Boolean, audioPlayable: Boolean): Engine {
        if (softwareDecoder || media3Failed || !audioPlayable) return Engine.VLC
        val wanted = when (setting) {
            EXOPLAYER -> true
            VLC -> false
            else -> dolbyVision != null && deviceDolbyVision
        }
        return if (wanted) Engine.MEDIA3 else Engine.VLC
    }

    /** Why VLC was kept, for the log; the order matches `decide`. */
    fun reasonVlc(setting: String, softwareDecoder: Boolean, media3Failed: Boolean, audioPlayable: Boolean): String = when {
        softwareDecoder -> "Software-Dekoder"
        media3Failed -> "Media3 gescheitert"
        !audioPlayable -> "Ton ohne Dekoder-Erweiterung nicht spielbar"
        setting == VLC -> "Einstellung VLC"
        else -> "Gerät ohne DV"
    }

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
