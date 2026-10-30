package org.traccar.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the GPS-off watcher alive when the app is closed. Android kills an app's process soon after
 * it is swiped away unless something in it runs as a foreground service, so this service holds the
 * location on/off receiver and shows a small, quiet "Location protection on" notification.
 */
class LocationGuardService : Service() {

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
        LocationGuard.registerReceiver(this)
        LocationGuard.check(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        LocationGuard.check(this)
        return START_STICKY
    }

    override fun onDestroy() {
        LocationGuard.unregisterReceiver(this)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Location protection", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shows that HiperTracker is checking location stays on"
                    setShowBadge(false)
                }
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pending = open?.let {
            PendingIntent.getActivity(this, 1, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle("HiperTracker")
            .setContentText("Location protection is on")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(pending)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "LocationGuardService"
        private const val CHANNEL_ID = "location_guard_service"
        private const val NOTIFICATION_ID = 7300

        /** Returns false if Android refused to start it (e.g. the app was started in the background). */
        fun start(context: Context): Boolean {
            return try {
                val intent = Intent(context, LocationGuardService::class.java)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                true
            } catch (e: Exception) {
                Log.w(TAG, "Could not start location protection service", e)
                false
            }
        }
    }
}

/** Starts the watcher again after the phone restarts or HiperTracker is updated. */
class LocationGuardBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> LocationGuard.start(context)
        }
    }
}
