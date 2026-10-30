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
import android.content.SharedPreferences
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
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Watches whether location is switched on and whether the app still has location permission,
 * and escalates when a worker turns it off:
 *
 *  1. Location turned off → the phone shows an alert ("turn it back on within 30 seconds or your
 *     manager will be notified") and the server records locationEnabled=false (no alarm yet).
 *  2. Every 30 seconds while it stays off → the phone alerts again (sound + vibration).
 *     The first of these re-checks (the 2nd trigger) sends alarm=gpsAntennaCut to the Traccar
 *     server, which notifies the worker's head (email, SMS, Telegram… as set up in Traccar).
 *  3. Location back on → the alert clears and the server records locationEnabled=true.
 *
 * Revoked location permission is handled the same way.
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

    /** How often to re-check and re-alert while location stays off. */
    private const val REMINDER_SECONDS = 30L

    private const val CHANNEL_ID = "location_alerts"
    private const val NOTIFICATION_ID = 7301

    private const val PREFS = "location_guard"
    private const val KEY_ARMED = "armed"
    private const val KEY_LAST_STATE = "last_state"
    private const val KEY_OFF_SINCE = "off_since"
    private const val KEY_REMINDERS = "reminders"
    private const val KEY_ESCALATED = "escalated"
    private const val KEY_QUEUE = "queue"

    // Flutter's shared_preferences (legacy Android backend) file and key prefix
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val FLUTTER_PREFIX = "flutter."

    private const val MAX_QUEUE = 50

    private val executor = Executors.newSingleThreadScheduledExecutor()

    @Volatile
    private var registered = false
    private var reminderTask: ScheduledFuture<*>? = null
    private var retryTask: ScheduledFuture<*>? = null
    private var retryAttempt = 0

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
        val prefs = prefs(app)
        val state = currentState(app)

        if (state == STATE_ON && !prefs.getBoolean(KEY_ARMED, false)) {
            prefs.edit().putBoolean(KEY_ARMED, true).apply()
        }
        val armed = prefs.getBoolean(KEY_ARMED, false)
        val last = prefs.getString(KEY_LAST_STATE, null)
        prefs.edit().putString(KEY_LAST_STATE, state).apply()

        if (state == STATE_ON) {
            stopReminders()
            cancelNotification(app)
            if (armed && last != null && last != STATE_ON) {
                Log.i(TAG, "Location back on")
                prefs.edit().remove(KEY_OFF_SINCE).remove(KEY_REMINDERS).remove(KEY_ESCALATED).apply()
                enqueue(app, STATE_ON, alarm = false, time = System.currentTimeMillis())
            }
        } else if (armed) {
            if (last != state) {
                // Newly turned off (or switched between off and no-permission): start a fresh episode
                Log.i(TAG, "Location state changed: $last -> $state")
                val now = System.currentTimeMillis()
                if (last == STATE_ON || last == null || !prefs.contains(KEY_OFF_SINCE)) {
                    prefs.edit().putLong(KEY_OFF_SINCE, now).putInt(KEY_REMINDERS, 0).putBoolean(KEY_ESCALATED, false).apply()
                }
                enqueue(app, state, alarm = false, time = now)
                showNotification(app, state, prefs.getInt(KEY_REMINDERS, 0), alert = true)
            } else {
                // Still off (e.g. app restarted): keep the alert visible without re-sounding it
                showNotification(app, state, prefs.getInt(KEY_REMINDERS, 0), alert = false)
            }
            startReminders(app)
        }

        flushQueue(app)
    }

    // ---- 30-second re-check and escalation ----

    private fun startReminders(app: Context) {
        if (reminderTask?.isDone == false) return
        reminderTask = executor.scheduleWithFixedDelay(
            { remind(app) }, REMINDER_SECONDS, REMINDER_SECONDS, TimeUnit.SECONDS
        )
    }

    private fun stopReminders() {
        reminderTask?.cancel(false)
        reminderTask = null
    }

    private fun remind(app: Context) {
        try {
            synchronized(this) {
                val state = currentState(app)
                if (state == STATE_ON) {
                    check(app) // clears the alert and reports "back on"
                    return
                }
                val prefs = prefs(app)
                val reminders = prefs.getInt(KEY_REMINDERS, 0) + 1
                prefs.edit().putInt(KEY_REMINDERS, reminders).apply()
                Log.i(TAG, "Location still off, reminder $reminders")

                if (!prefs.getBoolean(KEY_ESCALATED, false)) {
                    // 2nd trigger: tell the server, which notifies the worker's head
                    prefs.edit().putBoolean(KEY_ESCALATED, true).apply()
                    enqueue(app, state, alarm = true, time = System.currentTimeMillis())
                }
                showNotification(app, state, reminders, alert = true)
            }
            flushQueue(app)
        } catch (e: Exception) {
            Log.w(TAG, "Reminder failed", e)
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

    private fun prefs(app: Context): SharedPreferences = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Server reports (queued, so nothing is lost while the phone is offline) ----

    private data class Event(val state: String, val alarm: Boolean, val time: Long) {
        fun encode() = "$state|${if (alarm) 1 else 0}|$time"

        companion object {
            fun decode(line: String): Event? {
                val parts = line.split("|")
                if (parts.size != 3) return null
                val time = parts[2].toLongOrNull() ?: return null
                return Event(parts[0], parts[1] == "1", time)
            }
        }
    }

    @Synchronized
    private fun readQueue(app: Context): MutableList<Event> =
        (prefs(app).getString(KEY_QUEUE, "") ?: "").lines().mapNotNull { Event.decode(it) }.toMutableList()

    @Synchronized
    private fun writeQueue(app: Context, queue: List<Event>) {
        prefs(app).edit().putString(KEY_QUEUE, queue.takeLast(MAX_QUEUE).joinToString("\n") { it.encode() }).apply()
    }

    @Synchronized
    private fun enqueue(app: Context, state: String, alarm: Boolean, time: Long) {
        val queue = readQueue(app)
        queue.add(Event(state, alarm, time))
        writeQueue(app, queue)
    }

    private fun flushQueue(app: Context) {
        executor.execute { sendQueue(app) }
    }

    /** Runs on [executor]. Sends queued events in order; on failure retries with back-off. */
    private fun sendQueue(app: Context, fromRetry: Boolean = false) {
        if (fromRetry) retryTask = null
        while (true) {
            val event = readQueue(app).firstOrNull() ?: break
            val ok = try {
                post(app, event)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send location report", e)
                false
            }
            if (!ok) {
                if (retryTask == null) {
                    retryAttempt++
                    // 15s, 30s, 60s ... capped at 5 min; keeps retrying while the app is running
                    val delay = minOf(15L shl minOf(retryAttempt - 1, 5), 300L)
                    retryTask = executor.schedule({ sendQueue(app, fromRetry = true) }, delay, TimeUnit.SECONDS)
                }
                return
            }
            retryAttempt = 0
            synchronized(this) {
                val queue = readQueue(app)
                if (queue.firstOrNull() == event) {
                    queue.removeAt(0)
                    writeQueue(app, queue)
                }
            }
        }
    }

    private fun post(app: Context, event: Event): Boolean {
        val url = readSetting(app, "url")
        val id = readSetting(app, "id")
        if (url.isNullOrBlank() || id.isNullOrBlank()) return true // nothing configured; drop it

        val params = linkedMapOf(
            "id" to id,
            "timestamp" to (event.time / 1000).toString(),
            "locationEnabled" to (event.state == STATE_ON).toString(),
            "locationState" to event.state,
        )
        if (event.alarm) {
            params["alarm"] = ALARM
        }
        prefs(app).getLong(KEY_OFF_SINCE, 0).takeIf { it > 0 && event.state != STATE_ON }?.let {
            params["locationOffSince"] = (it / 1000).toString()
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
            Log.i(TAG, "Location report (${event.state}, alarm=${event.alarm}) sent, response $code")
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

    private fun showNotification(app: Context, state: String, reminders: Int, alert: Boolean) {
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "Location alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alerts when location is turned off during work"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            }
            nm.createNotificationChannel(channel)
        }

        val isOff = state == STATE_OFF
        val title = when {
            reminders == 0 && isOff -> "Location is turned off"
            reminders == 0 -> "Location permission removed"
            isOff -> "Location still off (reminder $reminders)"
            else -> "Location permission still removed (reminder $reminders)"
        }
        val fix = if (isOff) "Tap to turn location back on" else "Tap and set Location to \"Allow all the time\""
        val text = if (reminders == 0) {
            "Location must stay on during work. $fix within 30 seconds, or your manager will be notified."
        } else {
            "Your manager has been notified. $fix now."
        }
        val intent = if (isOff) {
            Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pendingIntent = PendingIntent.getActivity(
            app, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(app, CHANNEL_ID)
        } else {
            Notification.Builder(app)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        builder
            .setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_ERROR)
            .setOngoing(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setOnlyAlertOnce(!alert)
            .setContentIntent(pendingIntent)

        try {
            if (alert) nm.cancel(NOTIFICATION_ID) // re-posting fresh makes it sound and pop up again
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
