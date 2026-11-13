package org.traccar.client

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One accurate location fix for Check In / Check Out: GPS must be on, the phone listens to GPS (and network
 * as a helper) and answers as soon as a fix is within [GOOD_M] metres. After [TIMEOUT_MS] it takes the best
 * fresh fix if it's within [OK_M]; otherwise it refuses, so check-ins always have an accurate place, even
 * when tracking itself runs in battery-saving mode (Wi-Fi / mobile towers).
 * Replies to Flutter with {latitude, longitude, accuracy, time} or an error code:
 * "permission", "gps_off" or "inaccurate".
 */
object CurrentLocation {

    private const val TIMEOUT_MS = 30000L
    private const val GOOD_M = 25f
    private const val OK_M = 50f // never rougher than 50 m (the ERP checks its own limit too)

    @SuppressLint("MissingPermission")
    fun get(context: Context, result: MethodChannel.Result) {
        val app = context.applicationContext
        val fine = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine) {
            result.error("permission", "Precise location permission is not granted", null)
            return
        }
        val lm = app.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val gpsOn = try { lm.isProviderEnabled(LocationManager.GPS_PROVIDER) } catch (e: Exception) { false }
        if (!gpsOn) {
            result.error("gps_off", "Location (GPS) is switched off", null)
            return
        }
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter {
            try { lm.isProviderEnabled(it) } catch (e: Exception) { false }
        }

        val main = Handler(Looper.getMainLooper())
        val done = AtomicBoolean(false)
        val started = System.currentTimeMillis()
        var best: Location? = null
        val listeners = mutableListOf<LocationListener>()

        fun reply(location: Location?) {
            if (!done.compareAndSet(false, true)) return
            listeners.forEach { try { lm.removeUpdates(it) } catch (e: Exception) { } }
            if (location == null) {
                val acc = best?.let { if (it.hasAccuracy()) " (only ${it.accuracy.toInt()} m)" else "" } ?: ""
                result.error("inaccurate", "Could not get an accurate location$acc. Go outside or near a window and try again.", null)
            } else {
                result.success(
                    mapOf(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "accuracy" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
                        "time" to location.time,
                    )
                )
            }
        }

        fun consider(loc: Location) {
            if (loc.time < started - 5000 || !loc.hasAccuracy()) return // only fresh fixes
            if (best == null || loc.accuracy < best!!.accuracy) best = loc
            if (loc.accuracy <= GOOD_M) reply(loc)
        }

        for (provider in providers) {
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) = consider(location)
                @Deprecated("Deprecated in Java")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }
            listeners.add(listener)
            try {
                lm.requestLocationUpdates(provider, 1000L, 0f, listener, Looper.getMainLooper())
            } catch (e: Exception) {
                // try the other provider
            }
        }

        main.postDelayed({
            val b = best
            reply(if (b != null && b.accuracy <= OK_M) b else null)
        }, TIMEOUT_MS)
    }
}
