package com.nox.nox_iptv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/** Keeps the existing Flutter/ExoPlayer stream alive; never opens a second player. */
class PlaybackForegroundService : Service() {
    companion object {
        var onAction: ((String) -> Unit)? = null
        const val SHUTDOWN = "shutdown"
        private const val CHANNEL = "iptv_playback"
        private const val NOTIFICATION = 41
    }

    private lateinit var session: MediaSession
    private var title = "iptv-app"
    private var playing = false

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
        // Promote before MediaSession binder work or any command can return.
        // TV firmware can be slow to create a session; Android's deadline still
        // applies even when playback was cancelled during service startup.
        startForeground(NOTIFICATION, notification("iptv-app", false))
        session = MediaSession(this, "iptv-app").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { onAction?.invoke("play") }
                override fun onPause() { onAction?.invoke("pause") }
                override fun onStop() { stopPlayback() }
            })
            isActive = true
        }
    }

    private fun stopPlayback() {
        onAction?.invoke("stop")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == null) {
            playing = intent?.getBooleanExtra("playing", false) == true
            title = intent?.getStringExtra("title") ?: "iptv-app"
        }
        // Each foreground start must be acknowledged, including queued stops
        // and stale notification actions after the activity has gone away.
        startForeground(NOTIFICATION, notification(title, playing))
        if (onAction == null || intent?.action == SHUTDOWN) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent?.action) {
            "stop" -> { stopPlayback(); return START_NOT_STICKY }
            "play", "pause" -> {
                onAction?.invoke(intent.action!!)
                return START_NOT_STICKY
            }
        }
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, "iptv-app")
            .build())
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (playing) 1f else 0f)
            .build())
        return START_NOT_STICKY
    }

    private fun notification(title: String, playing: Boolean): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (::session.isInitialized) session.setSessionActivity(open)
        fun action(name: String) = PendingIntent.getService(this, name.hashCode(),
            Intent(this, PlaybackForegroundService::class.java).setAction(name),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val styled = if (::session.isInitialized) builder.setStyle(
            Notification.MediaStyle().setMediaSession(session.sessionToken)
                .setShowActionsInCompactView(0, 1)) else builder
        return styled
            .setSmallIcon(R.drawable.ic_playback_notification)
            .setContentTitle(title)
            .setContentText(if (playing) "Playing" else "Paused")
            .setContentIntent(open)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .setDeleteIntent(action("stop"))
            .addAction(Notification.Action.Builder(
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (playing) "Pause" else "Play", action(if (playing) "pause" else "play")).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel,
                "Stop", action("stop")).build())
            .build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) { stopPlayback() }
    override fun onDestroy() {
        if (::session.isInitialized) session.release()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
