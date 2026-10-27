package com.nox.nox_iptv

/** Physical TV Back: a click navigates back; a proven hold opens the preview.
 * Keep owning the release after fullscreen disables the gesture, so it cannot
 * immediately close the player. No timer or work when the remote is idle. */
internal class TvBackGesture(private val shortPress: () -> Unit, private val longPress: () -> Unit) {
    var enabled = false
        set(value) {
            field = value
            if (!value && captured && !held) interrupted = true
        }
    private var captured = false
    private var held = false
    private var interrupted = false

    fun down(repeat: Int, heldMs: Long): Boolean {
        if (repeat == 0) {
            captured = enabled
            held = false
            interrupted = false
        }
        if (!captured) return false
        if (repeat > 0 && heldMs >= 650 && !held && !interrupted && enabled) {
            held = true
            longPress()
        }
        return true
    }

    fun up(cancelled: Boolean): Boolean {
        if (!captured) return false
        captured = false
        if (!cancelled && !held && !interrupted) shortPress()
        return true
    }

    fun cancel() { interrupted = true }
}
