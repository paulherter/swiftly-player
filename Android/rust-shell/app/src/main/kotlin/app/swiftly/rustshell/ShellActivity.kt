package app.swiftly.rustshell

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Choreographer
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher

/**
 * Hosts the Rust UI: a SurfaceView that Rust draws to with wgpu/Vulkan, an invisible editor view for the soft
 * keyboard, D-pad and touch forwarding, system insets and Back. The Rust side owns the frame clock logic; this class
 * only posts a Choreographer frame when a call says one is wanted.
 */
class ShellActivity : Activity(), SurfaceHolder.Callback, Choreographer.FrameCallback {
    private lateinit var surfaceView: SurfaceView
    private lateinit var editor: EditorView
    private var framePosted = false
    private var keyboardShown = false
    private var backCallback: Any? = null

    private val isTv: Boolean
        get() = (getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION

    private var bare = false
    private var engine: Media3Engine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setDecorFitsSystemWindows(false)
        // `--ez bare true` (xtask android-smoke): no system bars and no insets, so a screenshot is the bare canvas.
        bare = intent.getBooleanExtra("bare", false)
        val metrics = resources.displayMetrics
        // The real app unless `--ez demo true` (scripted demo for the goldens) or `--es video` (engine test).
        val live = !intent.getBooleanExtra("demo", false) && intent.getStringExtra("video") == null
        if (live) {
            Native.initLive(Bridge(this), filesDir.path, cacheDir.path, Build.MODEL)
            Native.setLive(true)
            Native.setTransparent(true)
            // Test runs: `--es autologin "http://10.0.2.2:8096,user,pass"` signs in before the UI starts.
            intent.getStringExtra("autologin")?.split(",")?.takeIf { it.size == 3 }?.let { Native.autologin(it[0], it[1], it[2]) }
        }
        Native.create(isTv, metrics.widthPixels, metrics.heightPixels, metrics.density)

        // `--es video <path>`: a Media3 SurfaceView lies below the UI surface, which turns transparent (G3).
        val videoPath = intent.getStringExtra("video")
        if (live) {
            // `--es smokeplay "http://10.0.2.2:8096,user,pass|10"`: play the fixture clip through Media3 and log the result.
            intent.getStringExtra("smokeplay")?.split(",")?.takeIf { it.size == 4 }?.let { Native.smokePlay(it[0], it[1], it[2], it[3].toDouble()) }
        }
        surfaceView = SurfaceView(this)
        if (videoPath != null) Native.setTransparent(true)
        surfaceView.holder.addCallback(this)
        surfaceView.isFocusable = true
        surfaceView.isFocusableInTouchMode = true
        editor = EditorView(this) { kind, text -> handle(Native.text(kind, text)) }
        val root = android.widget.FrameLayout(this)
        if (videoPath != null || live) {
            val videoView = SurfaceView(this)
            root.addView(videoView)
            surfaceView.setZOrderMediaOverlay(true)
            surfaceView.holder.setFormat(android.graphics.PixelFormat.TRANSLUCENT)
            engine = Media3Engine(this, videoView)
            if (videoPath != null) Native.engineLoad(videoPath)
        }
        root.addView(surfaceView)
        root.addView(editor, android.widget.FrameLayout.LayoutParams(1, 1))
        setContentView(root)
        root.setOnApplyWindowInsetsListener { v, insets ->
            if (bare) v.windowInsetsController?.hide(WindowInsets.Type.systemBars())
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            if (bare) handle(Native.insets(0, 0, 0, 0)) else handle(Native.insets(bars.left, bars.top, bars.right, bars.bottom))
            insets
        }
        surfaceView.setOnTouchListener { _, e -> onTouch(e); true }
        surfaceView.requestFocus()
        registerBack()
    }

    private fun registerBack() {
        if (Build.VERSION.SDK_INT >= 33) {
            val cb = OnBackInvokedCallback { onBack() }
            backCallback = cb
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb)
        }
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onBackPressed() = onBack()

    // The Rust app handles Back while it has pages to pop; at the first page the system leaves the app.
    private fun onBack() {
        val flags = Native.back(SystemClock.uptimeMillis())
        handle(flags)
        if (flags and Native.FLAG_BACK_UNHANDLED != 0) finish()
    }

    // Phones: the first finger is the pointer; further fingers (pinch) are not forwarded yet.
    private fun onTouch(e: MotionEvent) {
        val phase = when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> 0
            MotionEvent.ACTION_MOVE -> 1
            MotionEvent.ACTION_UP -> 2
            MotionEvent.ACTION_CANCEL -> 3
            else -> return
        }
        if (phase == 1) {
            for (i in 0 until e.historySize) {
                Native.touch(1, e.getHistoricalX(i), e.getHistoricalY(i), e.getHistoricalEventTime(i))
            }
        }
        handle(Native.touch(phase, e.x, e.y, e.eventTime))
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // System Back goes through the back callback; everything else (D-pad, remote select, keyboard) is ours.
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
        val flags = Native.key(
            event.keyCode, event.action == KeyEvent.ACTION_DOWN, event.repeatCount > 0,
            event.unicodeChar, event.isShiftPressed, event.eventTime,
        )
        handle(flags)
        return flags and Native.FLAG_CHANGED != 0 || super.dispatchKeyEvent(event)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        handle(Native.surfaceChanged(holder.surface, width, height, resources.displayMetrics.density))
        postFrame()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Native.surfaceDestroyed()
    }

    override fun doFrame(frameTimeNanos: Long) {
        framePosted = false
        engine?.let {
            val cmds = Native.engineCommands()
            if (cmds.isNotEmpty()) it.apply(cmds)
            it.tick()
            postFrame()
        }
        handle(Native.frame(frameTimeNanos), fromFrame = true)
    }

    private fun postFrame() {
        if (!framePosted) {
            framePosted = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    /** Reads the flag set of a native call: next frame, soft keyboard. */
    private fun handle(flags: Int, fromFrame: Boolean = false) {
        if (flags and (Native.FLAG_WANTS_FRAME or if (fromFrame) 0 else Native.FLAG_CHANGED) != 0) postFrame()
        val wantsText = flags and Native.FLAG_WANTS_TEXT != 0
        if (wantsText != keyboardShown) {
            keyboardShown = wantsText
            val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
            if (wantsText) {
                editor.requestFocus()
                imm.showSoftInput(editor, 0)
            } else {
                imm.hideSoftInputFromWindow(editor.windowToken, 0)
                surfaceView.requestFocus()
            }
        }
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= 33) {
            (backCallback as? OnBackInvokedCallback)?.let { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it) }
        }
        engine?.release()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        postFrame()
    }
}

