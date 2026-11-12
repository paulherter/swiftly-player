package de.paulherter.swiftly

/**
 * The debug launch extra that carries a finished session JSON. `adb shell am start --es testSession '{"a":1}'` loses
 * the double quotes in the device shell (`{a:1}`), which then failed deep inside the session decoder with a bare
 * "DecodingError ... not valid JSON" after the sign-in step. That was the "JSON error" of the first smoke: the extra, not
 * the core. `testSessionB64` (base64 of the JSON) survives every shell; a plain extra is checked up front with a clear message.
 */
object DebugSessionExtra {
    /** The session JSON, or an error that says what to do. */
    fun read(plain: String?, base64: String?): Result<String> {
        val text = when {
            base64 != null -> runCatching { String(java.util.Base64.getDecoder().decode(base64.trim()), Charsets.UTF_8) }
                .getOrElse { return Result.failure(IllegalArgumentException("testSessionB64 is not base64")) }
            plain != null -> plain
            else -> return Result.failure(IllegalArgumentException("no session extra"))
        }.trim()
        val quoted = text.startsWith("{") && text.endsWith("}") && text.contains("\"accessToken\"")
        return if (quoted) Result.success(text)
        else Result.failure(IllegalArgumentException("testSession is not JSON (the device shell strips double quotes): pass testSessionB64 = base64 of the JSON"))
    }
}
