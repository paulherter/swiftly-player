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
 * **Mediensteuerung in Benachrichtigung und Sperrbildschirm** — das Gegenstueck zu
 * `MPNowPlayingInfoCenter`. Ein Vordergrunddienst mit `MediaStyle` an der Mediensitzung des
 * Players; Titel, Bild und Knoepfe kommen aus der Sitzung selbst (`Wiedergabezentrale` auf iOS).
 * Er haelt ausserdem die Wiedergabe am Leben, wenn der Bildschirm ausgeht.
 *
 * Ab Android 13 sind Benachrichtigungen einer Mediensitzung von der Benachrichtigungserlaubnis
 * ausgenommen — deshalb wird hier nicht gefragt.
 *
 * **Jeder Start ruft `startForeground`, auch einer, der gleich wieder endet.** Nach
 * `startForegroundService` bricht Android die App ab, wenn der Dienst ohne `startForeground` endet
 * (`ForegroundServiceDidNotStartInTimeException`) — ohne Mediensitzung (Player schon zu) und bei
 * `stopService` vor `onStartCommand` (Player schnell geschlossen) geschah genau das. Deshalb
 * starten und stoppen nur `an`/`aus`, nach demselben Muster wie `DownloadDienst`.
 */
class WiedergabeDienst : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as SwiftlyAnwendung
        val zeichen = app.medienToken
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
            .apply { if (zeichen != null) setStyle(Notification.MediaStyle().setMediaSession(zeichen)) }
            .build()
        val vorn = runCatching {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NUMMER, nachricht, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            else startForeground(NUMMER, nachricht)
        }.onFailure { Protokoll.schreib("[Dienst] Wiedergabe nicht im Vordergrund: ${it.javaClass.simpleName}") }.isSuccess
        if (offen > 0) offen--
        // Ohne Sitzung oder schon abbestellt: erst jetzt, nach `startForeground`, darf der Dienst enden.
        // Mit `startId`: steht schon ein weiterer Start aus, bleibt der Dienst fuer dessen `startForeground`.
        if (!vorn || zeichen == null || !gewuenscht) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(startId) }
        return START_NOT_STICKY
    }

    companion object {
        private const val KANAL = "wiedergabe"
        private const val NUMMER = 1
        /** Der Player will den Dienst — `aus` nimmt es zurueck. */
        @Volatile private var gewuenscht = false
        /**
         * Gestartete, deren `onStartCommand` noch aussteht. Jeder `startForegroundService` verlangt ein
         * eigenes `startForeground` — auch beim schon laufenden Dienst (neue Folge, Laenge bekannt).
         */
        @Volatile private var offen = 0

        fun an(k: Context, titel: String, untertitel: String) {
            // Aus dem Hintergrund darf ein Vordergrunddienst nicht immer starten; die Wiedergabe laeuft trotzdem.
            runCatching {
                androidx.core.content.ContextCompat.startForegroundService(k, Intent(k, WiedergabeDienst::class.java)
                    .putExtra("titel", titel).putExtra("untertitel", untertitel))
                gewuenscht = true
                offen++
            }.onFailure { Protokoll.schreib("[Dienst] Wiedergabe nicht gestartet: ${it.javaClass.simpleName}") }
        }

        fun aus(k: Context) {
            if (!gewuenscht) return
            gewuenscht = false
            // Vor `onStartCommand` beendet, bricht Android die App ab; dann endet der Dienst dort.
            if (offen == 0) runCatching { k.stopService(Intent(k, WiedergabeDienst::class.java)) }
        }
    }
}
