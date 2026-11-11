package org.traccar.client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * The navigation card in the notification bar and on the lock screen while a trip is being driven,
 * like Google Maps: next turn, distance, arrival time, progress and "Exit navigation".
 */
object NavNotification {
    private const val CHANNEL = "hipertracker_navigation"
    private const val ID = 7301
    const val ACTION_EXIT = "org.traccar.client.EXIT_NAVIGATION"

    private fun channel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Trip navigation", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Next turn and arrival time while you drive a trip"
                    setShowBadge(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
            )
        }
    }

    fun show(
        context: Context,
        title: String,
        text: String,
        icon: ByteArray?,
        progress: Int,
        color: Int,
    ) {
        channel(context)
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val exit = PendingIntent.getActivity(
            context, 1,
            Intent(context, MainActivity::class.java).setAction(ACTION_EXIT).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setColor(color)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setProgress(1000, progress.coerceIn(0, 1000), false)
            .addAction(0, "Exit navigation", exit)
        if (icon != null) {
            BitmapFactory.decodeByteArray(icon, 0, icon.size)?.let { b.setLargeIcon(it) }
        }
        try {
            NotificationManagerCompat.from(context).notify(ID, b.build())
        } catch (e: SecurityException) {
            // notifications not allowed: nothing to show
        }
    }

    fun hide(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID)
    }
}
