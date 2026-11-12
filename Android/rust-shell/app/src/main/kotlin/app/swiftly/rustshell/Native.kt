package app.swiftly.rustshell

/** The six-plus JNI calls of libswiftly_android.so. Every call returns the flag set below. */
object Native {
    const val FLAG_WANTS_FRAME = 1
    const val FLAG_WANTS_TEXT = 2
    const val FLAG_CHANGED = 4
    const val FLAG_BACK_UNHANDLED = 8

    // Text kinds for [text].
    const val TEXT_COMMIT = 0
    const val TEXT_PREEDIT = 1
    const val TEXT_CANCEL = 2
    const val TEXT_BACKSPACE = 3
    const val TEXT_SUBMIT = 4

    init { System.loadLibrary("swiftly_android") }

    @JvmStatic external fun create(tv: Boolean, width: Int, height: Int, density: Float)
    @JvmStatic external fun surfaceChanged(surface: android.view.Surface, width: Int, height: Int, density: Float): Int
    @JvmStatic external fun surfaceDestroyed()
    @JvmStatic external fun insets(left: Int, top: Int, right: Int, bottom: Int): Int
    @JvmStatic external fun touch(phase: Int, x: Float, y: Float, eventTimeMs: Long): Int
    @JvmStatic external fun key(code: Int, down: Boolean, repeat: Boolean, unicode: Int, shift: Boolean, eventTimeMs: Long): Int
    @JvmStatic external fun back(eventTimeMs: Long): Int
    @JvmStatic external fun text(kind: Int, text: String?): Int
    @JvmStatic external fun frame(frameTimeNanos: Long): Int

    // The engine wire (G3): JSON lines, see swiftly_player_surface::wire.
    @JvmStatic external fun engineEvent(json: String): Boolean
    @JvmStatic external fun engineCommands(): String
    @JvmStatic external fun engineLoad(url: String)
    @JvmStatic external fun setTransparent(on: Boolean)

    // The real app (platform pieces the Rust core calls back: HTTP and secrets live in [Bridge]).
    @JvmStatic external fun initLive(bridge: Bridge, filesDir: String, cacheDir: String, deviceName: String)
    @JvmStatic external fun setLive(on: Boolean)
    @JvmStatic external fun autologin(address: String, user: String, password: String)
    @JvmStatic external fun smokePlay(address: String, user: String, password: String, seconds: Double)
}
