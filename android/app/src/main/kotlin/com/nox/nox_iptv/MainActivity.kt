package com.nox.nox_iptv

import android.app.KeyguardManager
import android.os.PowerManager
import android.content.BroadcastReceiver
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import android.app.PictureInPictureParams
import android.app.PictureInPictureUiState
import android.graphics.Rect
import android.util.Rational
import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Exposes ActivityManager's real device memory info to Dart — Flutter has
 * no built-in way to ask "how much RAM does this specific device have",
 * and the app's image cache ceiling needs that to scale itself per device
 * instead of using one fixed number for every Firestick regardless of how
 * much headroom it actually has (see main.dart's _configureImageCache).
 * Mirrors how Glide, the standard Android image-loading library, sizes
 * its own cache via ActivityManager.isLowRamDevice()/getMemoryInfo().
 *
 * Also exposes the "install a downloaded update APK" flow for
 * AppUpdateService's in-app "Check for Updates" — no Flutter plugin
 * covers this on its own, since it involves both a permission check only
 * meaningful on Android 8+ and handing another app (the system installer)
 * a content:// URI via FileProvider, which needs the provider declared in
 * AndroidManifest.xml/res/xml/file_paths.xml.
 */
class MainActivity : FlutterActivity() {
    private var remoteChannel: MethodChannel? = null
    private val remoteBack = TvBackGesture(
        shortPress = { normalRemoteBack() },
        longPress = {
            remoteChannel?.invokeMethod("fullscreen", null, object : MethodChannel.Result {
                override fun success(result: Any?) { if (result != true) normalRemoteBack() }
                override fun error(code: String, message: String?, details: Any?) { normalRemoteBack() }
                override fun notImplemented() { normalRemoteBack() }
            })
        })

    @Suppress("DEPRECATION")
    private fun normalRemoteBack() { if (!activityStopped) super.onBackPressed() }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            val consumed = when (event.action) {
                KeyEvent.ACTION_DOWN -> remoteBack.down(event.repeatCount, event.eventTime - event.downTime)
                KeyEvent.ACTION_UP -> remoteBack.up(event.isCanceled)
                else -> false
            }
            if (consumed) return true
        } else if (event.action == KeyEvent.ACTION_DOWN) {
            remoteBack.cancel()
        }
        return super.dispatchKeyEvent(event)
    }
    private val MEMORY_CHANNEL = "com.nox.nox_iptv/device_memory"
    private val UPDATE_CHANNEL = "com.nox.nox_iptv/app_update"
    private val DEVICE_CHANNEL = "com.nox.nox_iptv/device_type"

    private var pipChannel: MethodChannel? = null
    private var pipEnabled = false
    private var pipRatio = 16.0 / 9.0
    private var activityStopped = false
    private var wasPipSinceResume = false
    private var mediaSessionEnabled = false
    private var mediaPlaying = false
    private var playbackServiceStarted = false
    private var screenOffPlayback = false

    private fun isScreenLocked(): Boolean =
        !getSystemService(PowerManager::class.java).isInteractive ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun reportBackground(resume: Boolean, dismissed: Boolean = false) {
        screenOffPlayback = mediaSessionEnabled && isScreenLocked()
        pipChannel?.invokeMethod("background", mapOf(
            "resume" to resume, "screenOff" to screenOffPlayback,
            "dismissed" to (dismissed && !screenOffPlayback)))
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    if (mediaSessionEnabled && mediaPlaying) {
                        screenOffPlayback = true
                        pipChannel?.invokeMethod("background", mapOf(
                            "resume" to false, "screenOff" to true))
                    }
                }
                Intent.ACTION_USER_PRESENT -> {
                    val pip = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode
                    if (screenOffPlayback) {
                        if (activityStopped && !pip) reportBackground(false)
                        else {
                            screenOffPlayback = false
                            pipChannel?.invokeMethod("foreground", null)
                        }
                    }
                }
            }
        }
    }

    private fun shutdownPlaybackService() {
        if (!playbackServiceStarted) return
        playbackServiceStarted = false
        try {
            // Keep stop ordered behind a pending start during channel changes.
            startService(Intent(this, PlaybackForegroundService::class.java)
                .setAction(PlaybackForegroundService.SHUTDOWN))
        } catch (_: IllegalStateException) {
            // The OS may already have stopped the service while backgrounded.
            stopService(Intent(this, PlaybackForegroundService::class.java))
        }
    }

    private fun updatePlaybackService(title: String) {
        if (!mediaSessionEnabled) {
            shutdownPlaybackService()
            return
        }
        if (!playbackServiceStarted && activityStopped) return
        val intent = Intent(this, PlaybackForegroundService::class.java)
            .putExtra("title", title).putExtra("playing", mediaPlaying)
        try {
            // We start only from a visible activity (or update an existing
            // foreground service). onCreate promotes immediately. A normal
            // start avoids a foreground-start deadline expiring while the TV's
            // main thread is busy creating its native video decoder/view.
            startService(intent)
            playbackServiceStarted = true
        } catch (_: IllegalStateException) {
            playbackServiceStarted = false
        } catch (_: SecurityException) {
            playbackServiceStarted = false
        }
    }


    private fun supportsPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams {
        val ratio = pipRatio.coerceIn(0.42, 2.39)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((ratio * 10000).toInt(), 10000))
        // Crop the transition to the video, excluding portrait letterboxing.
        val bounds = Rect()
        window.decorView.getGlobalVisibleRect(bounds)
        if (!bounds.isEmpty) {
            val width = minOf(bounds.width(), (bounds.height() * ratio).toInt())
            val height = minOf(bounds.height(), (bounds.width() / ratio).toInt())
            val left = bounds.centerX() - width / 2
            val top = bounds.centerY() - height / 2
            builder.setSourceRectHint(Rect(left, top, left + width, top + height))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun updatePipParams() {
        if (!supportsPip()) return
        try {
            setPictureInPictureParams(pipParams())
        } catch (_: IllegalArgumentException) {
            // OEM implementations can impose stricter aspect-ratio limits.
        } catch (_: IllegalStateException) {
            // Activity is already leaving.
        }
    }

    private fun enterPip(): Boolean {
        if (!supportsPip() || !pipEnabled || activityStopped) return false
        return try {
            enterPictureInPictureMode(pipParams())
        } catch (_: IllegalStateException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) wasPipSinceResume = true
        pipChannel?.invokeMethod("modeChanged", isInPictureInPictureMode)
        // Closing PiP can deliver its mode callback after onStop.
        if (!isInPictureInPictureMode && activityStopped) {
            reportBackground(false, dismissed = true)
        }
    }

    override fun onPictureInPictureUiStateChanged(pipState: PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(pipState)
        if (Build.VERSION.SDK_INT >= 35 && pipState.isTransitioningToPip) {
            pipChannel?.invokeMethod("modeChanged", true)
        }
    }

    override fun onStart() {
        super.onStart()
        activityStopped = false
        screenOffPlayback = false
        pipChannel?.invokeMethod("foreground", null)
    }

    override fun onResume() {
        super.onResume()
        wasPipSinceResume = false
    }

    override fun onStop() {
        remoteBack.cancel()
        activityStopped = true
        val wasPip = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode
        // Visible PiP stays STARTED. STOPPED means hidden/dismissed.
        reportBackground(!(wasPip || wasPipSinceResume), dismissed = wasPip || wasPipSinceResume)
        super.onStop()
    }

    override fun onDestroy() {
        remoteBack.enabled = false
        remoteChannel?.setMethodCallHandler(null)
        unregisterReceiver(screenReceiver)
        PlaybackForegroundService.onAction = null
        shutdownPlaybackService()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        remoteChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.nox.nox_iptv/tv_remote").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "setEnabled") {
                    remoteBack.enabled = call.arguments == true
                    result.success(null)
                } else result.notImplemented()
            }
        }
        ContextCompat.registerReceiver(this, screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        PlaybackForegroundService.onAction = { action ->
            pipChannel?.invokeMethod("mediaAction", action)
        }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.nox.nox_iptv/picture_in_picture").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(supportsPip())
                    "update" -> {
                        pipEnabled = call.argument<Boolean>("enabled") == true
                        val ratio = call.argument<Double>("aspectRatio") ?: (16.0 / 9.0)
                        pipRatio = if (ratio.isFinite() && ratio > 0) ratio else 16.0 / 9.0
                        mediaSessionEnabled = call.argument<Boolean>("mediaSession") == true
                        mediaPlaying = call.argument<Boolean>("playing") == true
                        updatePlaybackService(call.argument<String>("title") ?: "iptv-app")
                        updatePipParams()
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }
        window.decorView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            if (pipEnabled) updatePipParams()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getMemoryInfo") {
                val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memoryInfo = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(memoryInfo)
                result.success(
                    mapOf(
                        "totalMemBytes" to memoryInfo.totalMem,
                        "isLowRamDevice" to activityManager.isLowRamDevice
                    )
                )
            } else {
                result.notImplemented()
            }
        }

        // Is this actually a television? Asked because the previous
        // "auto" layout heuristic compared MediaQuery width against a
        // fixed logical-pixel threshold, and a 1080p TV running at 2x
        // density reports 960dp — under the threshold — so every Android
        // TV box and Fire Stick silently got the phone layout on first
        // launch. Screen size cannot distinguish a TV from a tablet;
        // Android's own UI mode can.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isTelevision") {
                val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                val isTvUiMode = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                // Leanback is what a TV launcher requires of an app, and is
                // present on Fire TV even where the UI mode is reported
                // inconsistently, so either signal is enough.
                val hasLeanback =
                    packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
                result.success(isTvUiMode || hasLeanback)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestInstalls" -> {
                    // Only a real gate on Android 8 (API 26)+ — earlier
                    // versions have no per-app "unknown sources" toggle at
                    // all, installing from any source just works.
                    val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(canInstall)
                }
                "requestInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        intent.data = Uri.parse("package:$packageName")
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                    }
                    result.success(null)
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("NO_PATH", "filePath argument missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
