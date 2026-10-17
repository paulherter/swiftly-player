package de.paulherter.swiftly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Media controls in the notification and on the lock screen (counterpart of
 * `MPNowPlayingInfoCenter`). A foreground service with `MediaStyle` on the player's media
 * session; title, image and buttons come from the session itself. It also keeps playback alive
 * when the screen goes off.
 *
 * From Android 13, media-session notifications are exempt from the notification permission, so
 * nothing is asked here.
 *
 * Every start calls `startForeground`, even one that ends right away. After
 * `startForegroundService`, Android kills the app if the service ends without `startForeground`
 * (`ForegroundServiceDidNotStartInTimeException`). That happened without a media session (player
 * already closed) and with `stopService` before `onStartCommand` (player closed quickly). So only
 * `an`/`aus` start and stop it, same pattern as `DownloadService`.
 */
class PlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as SwiftlyApplication
        val symbolText = app.mediaToken
        val handler = getSystemService(NotificationManager::class.java)
        if (handler.getNotificationChannel(Channel) == null) {
            handler.createNotificationChannel(NotificationChannel(Channel, "Wiedergabe", NotificationManager.IMPORTANCE_LOW))
        }
        val back = PendingIntent.getActivity(this, 0, Intent(this, PlayerActivity::class.java),
                                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val postDirection = Notification.Builder(this, Channel)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(intent?.getStringExtra("titel").orEmpty())
            .setContentText(intent?.getStringExtra("untertitel").orEmpty())
            .setContentIntent(back)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .apply { if (symbolText != null) setStyle(Notification.MediaStyle().setMediaSession(symbolText)) }
            .build()
        val front = runCatching {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NUMBER, postDirection, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            else startForeground(NUMBER, postDirection)
        }.onFailure { AppLog.writeOut("[Dienst] Wiedergabe nicht im Vordergrund: ${it.javaClass.simpleName}") }.isSuccess
        if (opened > 0) opened--
        // Without a session or already unsubscribed: only now, after `startForeground`, may the service
        // end. With `startId`: if another start is pending, the service stays for its `startForeground`.
        if (!front || symbolText == null || !wished) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(startId) }
        return START_NOT_STICKY
    }

    companion object {
        private const val Channel = "wiedergabe"
        private const val NUMBER = 1
        /** The player wants the service; `aus` takes it back. */
        @Volatile private var wished = false
        /**
         * Starts whose `onStartCommand` is still pending. Every `startForegroundService` needs its
         * own `startForeground`, also when the service is already running (new episode, length known).
         */
        @Volatile private var opened = 0

        fun an(k: Context, title: String, subtitle: String) {
            // A foreground service may not always start from the background; playback runs regardless.
            runCatching {
                androidx.core.content.ContextCompat.startForegroundService(k, Intent(k, PlaybackService::class.java)
                    .putExtra("titel", title).putExtra("untertitel", subtitle))
                wished = true
                opened++
            }.onFailure { AppLog.writeOut("[Dienst] Wiedergabe nicht gestartet: ${it.javaClass.simpleName}") }
        }

        fun from(k: Context) {
            if (!wished) return
            wished = false
            // If it ended before `onStartCommand`, Android kills the app; so the service ends there.
            if (opened == 0) runCatching { k.stopService(Intent(k, PlaybackService::class.java)) }
        }
    }
}
