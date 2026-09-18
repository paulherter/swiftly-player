package de.paulherter.swiftly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * **Mediensteuerung in Benachrichtigung und Sperrbildschirm** — das Gegenstueck zu
 * `MPNowPlayingInfoCenter`. Ein Vordergrunddienst mit `MediaStyle` an der Mediensitzung des
 * Players; Titel, Bild und Knoepfe kommen aus der Sitzung selbst (`Wiedergabezentrale` auf iOS).
 * Er haelt ausserdem die Wiedergabe am Leben, wenn der Bildschirm ausgeht.
 *
 * Ab Android 13 sind Benachrichtigungen einer Mediensitzung von der Benachrichtigungserlaubnis
 * ausgenommen — deshalb wird hier nicht gefragt.
 */
class WiedergabeDienst : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as SwiftlyAnwendung
        val zeichen = app.medienToken ?: run { stopSelf(); return START_NOT_STICKY }
        val verwalter = getSystemService(NotificationManager::class.java)
        if (verwalter.getNotificationChannel(KANAL) == null) {
            verwalter.createNotificationChannel(NotificationChannel(KANAL, "Wiedergabe", NotificationManager.IMPORTANCE_LOW))
        }
        val zurueck = PendingIntent.getActivity(this, 0, Intent(this, PlayerAktivitaet::class.java),
                                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val nachricht = Notification.Builder(this, KANAL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(intent?.getStringExtra("titel").orEmpty())
            .setContentText(intent?.getStringExtra("untertitel").orEmpty())
            .setContentIntent(zurueck)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setStyle(Notification.MediaStyle().setMediaSession(zeichen))
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NUMMER, nachricht, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NUMMER, nachricht)
        return START_NOT_STICKY
    }

    companion object {
        private const val KANAL = "wiedergabe"
        private const val NUMMER = 1
    }
}
