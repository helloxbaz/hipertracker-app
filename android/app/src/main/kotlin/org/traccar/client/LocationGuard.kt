package org.traccar.client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Watches whether location is switched on and whether the app still has location permission.
 *
 * When a worker turns location off (or revokes permission), it:
 *  1. shows a persistent, high-priority notification asking them to turn it back on, and
 *  2. sends an alarm to the Traccar server (alarm=gpsAntennaCut, locationEnabled=false),
 *     so admins get a notification in Traccar.
 * When location comes back on, it clears the notification and sends locationEnabled=true.
 *
 * Alerts only start once the phone has been set up (location seen on with permission at least once),
 * so a freshly installed phone doesn't raise false alarms before onboarding.
 */
object LocationGuard {

    private const val TAG = "LocationGuard"

    const val STATE_ON = "on"
    const val STATE_OFF = "off"
    const val STATE_NO_PERMISSION = "no_permission"

    /** Standard Traccar alarm type, so it can be picked in Traccar's notification settings. */
    private const val ALARM = "gpsAntennaCut"

    private const val CHANNEL_ID = "location_guard"
    private const val NOTIFICATION_ID = 7301

    private const val PREFS = "location_guard"
    private const val KEY_ARMED = "armed"
    private const val KEY_LAST_STATE = "last_state"
    private const val KEY_PENDING_STATE = "pending_state"
    private const val KEY_PENDING_TIME = "pending_time"

    // Flutter's shared_preferences (legacy Android backend) file and key prefix
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val FLUTTER_PREFIX = "flutter."

    private const val MAX_ATTEMPTS = 8

    private val executor = Executors.newSingleThreadScheduledExecutor()

    @Volatile
    private var registered = false

    fun start(context: Context) {
        val app = context.applicationContext
        if (!registered) {
            val filter = IntentFilter().apply {
                addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
                addAction(LocationManager.MODE_CHANGED_ACTION)
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, intent: Intent) {
                    check(app)
                }
            }
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                app.registerReceiver(receiver, filter)
            }
            registered = true
        }
        check(app)
    }

    fun currentState(context: Context): String = when {
        !hasPermission(context) -> STATE_NO_PERMISSION
        !isLocationEnabled(context) -> STATE_OFF
        else -> STATE_ON
    }

    @Synchronized
    fun check(context: Context) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val state = currentState(app)

        if (state == STATE_ON && !prefs.getBoolean(KEY_ARMED, false)) {
            prefs.edit().putBoolean(KEY_ARMED, true).apply()
        }
        val armed = prefs.getBoolean(KEY_ARMED, false)

        if (state == STATE_ON) {
            cancelNotification(app)
        } else if (armed) {
            showNotification(app, state)
        }

        val last = prefs.getString(KEY_LAST_STATE, null)
        if (state != last) {
            prefs.edit().putString(KEY_LAST_STATE, state).apply()
            if (armed && last != null) {
                Log.i(TAG, "Location state changed: $last -> $state")
                prefs.edit()
                    .putString(KEY_PENDING_STATE, state)
                    .putLong(KEY_PENDING_TIME, System.currentTimeMillis())
                    .apply()
            }
        }

        if (prefs.getString(KEY_PENDING_STATE, null) != null) {
            executor.execute { sendPending(app, 1) }
        }
    }

    private fun hasPermission(context: Context): Boolean {
        return context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationEnabled(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= 28) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    // ---- Server alert ----

    private fun sendPending(app: Context, attempt: Int) {
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val state = prefs.getString(KEY_PENDING_STATE, null) ?: return
        val time = prefs.getLong(KEY_PENDING_TIME, System.currentTimeMillis())

        val ok = try {
            post(app, state, time)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send location alert", e)
            false
        }

        if (ok) {
            // Only clear if nothing newer was queued meanwhile
            synchronized(this) {
                if (prefs.getString(KEY_PENDING_STATE, null) == state &&
                    prefs.getLong(KEY_PENDING_TIME, 0) == time
                ) {
                    prefs.edit().remove(KEY_PENDING_STATE).remove(KEY_PENDING_TIME).apply()
                }
            }
        } else if (attempt < MAX_ATTEMPTS) {
            // 15s, 30s, 60s ... capped at 10 min. Still pending after that? It's retried on the next check.
            val delay = minOf(15L shl (attempt - 1), 600L)
            executor.schedule({ sendPending(app, attempt + 1) }, delay, TimeUnit.SECONDS)
        }
    }

    private fun post(app: Context, state: String, time: Long): Boolean {
        val url = readSetting(app, "url")
        val id = readSetting(app, "id")
        if (url.isNullOrBlank() || id.isNullOrBlank()) return true // nothing configured; drop it

        val params = linkedMapOf(
            "id" to id,
            "timestamp" to (time / 1000).toString(),
            "locationEnabled" to (state == STATE_ON).toString(),
            "locationState" to state,
        )
        if (state != STATE_ON) {
            params["alarm"] = ALARM
        }
        lastKnownLocation(app)?.let {
            params["lat"] = it.latitude.toString()
            params["lon"] = it.longitude.toString()
            if (it.hasAccuracy()) params["accuracy"] = it.accuracy.toString()
        }
        val body = params.entries.joinToString("&") {
            "${URLEncoder.encode(it.key, "UTF-8")}=${URLEncoder.encode(it.value, "UTF-8")}"
        }

        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15000
            connection.readTimeout = 15000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            connection.outputStream.use { it.write(body.toByteArray()) }
            val code = connection.responseCode
            Log.i(TAG, "Location alert ($state) sent, response $code")
            return code in 200..299
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Reads a setting saved by the Flutter side. The app uses the legacy Android SharedPreferences
     * backend with no file name, i.e. the default preferences file with plain keys; the classic
     * Flutter file with "flutter." keys is checked as a fallback.
     */
    private fun readSetting(app: Context, key: String): String? {
        val defaultPrefs = app.getSharedPreferences(app.packageName + "_preferences", Context.MODE_PRIVATE)
        val value = try { defaultPrefs.getString(key, null) } catch (e: ClassCastException) { null }
        if (!value.isNullOrBlank()) return value
        val flutterPrefs = app.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        return try { flutterPrefs.getString(FLUTTER_PREFIX + key, null) } catch (e: ClassCastException) { null }
    }

    private fun lastKnownLocation(context: Context): Location? {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        var best: Location? = null
        for (provider in lm.allProviders) {
            val location = try {
                lm.getLastKnownLocation(provider)
            } catch (e: SecurityException) {
                null
            } catch (e: IllegalArgumentException) {
                null
            } ?: continue
            if (best == null || location.time > best.time) best = location
        }
        return best
    }

    // ---- Phone notification ----

    private fun showNotification(app: Context, state: String) {
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Location alerts", NotificationManager.IMPORTANCE_HIGH)
            )
        }

        val (title, text, intent) = if (state == STATE_OFF) {
            Triple(
                "Location is turned off",
                "Location must stay on during work. Tap to turn it back on. Your company has been notified.",
                Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS),
            )
        } else {
            Triple(
                "Location permission removed",
                "Location permission is required during work. Tap and set Location to \"Allow all the time\". Your company has been notified.",
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null)),
            )
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pendingIntent = PendingIntent.getActivity(
            app, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(app, CHANNEL_ID)
        } else {
            Notification.Builder(app).setPriority(Notification.PRIORITY_HIGH)
        }
        builder
            .setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_ERROR)
            .setOngoing(true)
            .setContentIntent(pendingIntent)

        try {
            nm.notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification permission missing", e)
        }
    }

    private fun cancelNotification(app: Context) {
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }
}
