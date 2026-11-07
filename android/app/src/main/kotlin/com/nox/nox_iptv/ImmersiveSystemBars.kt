package com.nox.nox_iptv

import android.view.Window
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

/** Hides bars without opting out of Android 15/16 edge-to-edge layout. */
internal class ImmersiveSystemBars(private val window: Window) {
    private var active = false
    private var previousVisible = 0
    private var previousBehavior = 0
    private val barTypes = intArrayOf(
        WindowInsetsCompat.Type.statusBars(),
        WindowInsetsCompat.Type.navigationBars(),
        WindowInsetsCompat.Type.captionBar(),
    )

    fun setImmersive(enabled: Boolean) {
        if (enabled == active) return
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (enabled) {
            val insets = ViewCompat.getRootWindowInsets(window.decorView)
            previousVisible = barTypes.filter { insets?.isVisible(it) != false }
                .fold(0) { mask, type -> mask or type }
            previousBehavior = controller.systemBarsBehavior
            active = true
            onWindowFocusChanged(true)
        } else {
            active = false
            controller.systemBarsBehavior = previousBehavior
            controller.show(previousVisible)
            controller.hide(WindowInsetsCompat.Type.systemBars() and previousVisible.inv())
        }
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!active || !hasFocus) return
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }
}
