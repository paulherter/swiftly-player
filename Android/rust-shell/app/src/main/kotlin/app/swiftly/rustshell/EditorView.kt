package app.swiftly.rustshell

import android.content.Context
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/**
 * The invisible view that owns the soft keyboard. It is an InputConnection STUB: it forwards composing text, commits,
 * single-character deletes and the action key to Rust, but does not mirror the field's text, selection or composing
 * region back, so autocorrect context, cursor taps in the keyboard and "delete word" gestures are limited. The full
 * bridge (editable mirror, `updateSelection`, `getTextBeforeCursor`) is listed in the source.
 */
class EditorView(context: Context, private val send: (kind: Int, text: String?) -> Unit) : View(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT
        outAttrs.imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                send(Native.TEXT_COMMIT, text?.toString())
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                send(Native.TEXT_PREEDIT, text?.toString() ?: "")
                return true
            }

            override fun finishComposingText(): Boolean {
                send(Native.TEXT_CANCEL, null)
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtLeast(0)) { send(Native.TEXT_BACKSPACE, null) }
                return true
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                send(Native.TEXT_SUBMIT, null)
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                // Hardware-style keys from the keyboard (DEL, Enter) arrive here on some keyboards.
                if (event.action == KeyEvent.ACTION_DOWN) {
                    when (event.keyCode) {
                        KeyEvent.KEYCODE_DEL -> send(Native.TEXT_BACKSPACE, null)
                        KeyEvent.KEYCODE_ENTER -> send(Native.TEXT_SUBMIT, null)
                        else -> return super.sendKeyEvent(event)
                    }
                }
                return true
            }
        }
    }
}
