package de.paulherter.swiftly

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.WindowManager
import android.widget.FrameLayout

/** A black, full-screen host with one `FrameLayout` for the player's picture (subtitle contract test). */
class ProbeActivity : Activity() {
    lateinit var host: FrameLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        host = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        setContentView(host)
    }
}
