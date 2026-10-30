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
 * One fresh location fix for Check In / Check Out. Asks GPS and network at the same time and
 * answers with the first fix; after [TIMEOUT_MS] falls back to the newest last-known location.
 * Replies to Flutter with {latitude, longitude, accuracy, time} or an error code:
 * "permission" (no location permission) or "gps_off" (location switched off) or "no_fix".
 */
object CurrentLocation {

    private const val TIMEOUT_MS = 25000L
    private const val MAX_LAST_KNOWN_AGE_MS = 10 * 60 * 1000L

    @SuppressLint("MissingPermission")
    fun get(context: Context, result: MethodChannel.Result) {
        val app = context.applicationContext
        val fine = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = app.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            result.error("permission", "Location permission is not granted", null)
            return
        }
        val lm = app.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter {
            try { lm.isProviderEnabled(it) } catch (e: Exception) { false }
        }
        if (providers.isEmpty()) {
            result.error("gps_off", "Location is switched off", null)
            return
        }

        val main = Handler(Looper.getMainLooper())
        val done = AtomicBoolean(false)
        val listeners = mutableListOf<LocationListener>()

        fun finish(location: Location?) {
            if (!done.compareAndSet(false, true)) return
            listeners.forEach { try { lm.removeUpdates(it) } catch (e: Exception) { } }
            if (location == null) {
                result.error("no_fix", "Could not get your location. Go outside or near a window and try again.", null)
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

        for (provider in providers) {
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    lm.getCurrentLocation(provider, null, app.mainExecutor) { loc -> if (loc != null) finish(loc) }
                } catch (e: Exception) {
                    // try the next provider
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = finish(location)
                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {}
                }
                listeners.add(listener)
                try {
                    @Suppress("DEPRECATION")
                    lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                } catch (e: Exception) {
                    // try the next provider
                }
            }
        }

        main.postDelayed({
            // no fresh fix in time: use the newest recent last-known location, if any
            var best: Location? = null
            for (provider in providers + LocationManager.PASSIVE_PROVIDER) {
                val loc = try { lm.getLastKnownLocation(provider) } catch (e: Exception) { null } ?: continue
                if (best == null || loc.time > best.time) best = loc
            }
            val recent = best?.takeIf { System.currentTimeMillis() - it.time < MAX_LAST_KNOWN_AGE_MS }
            finish(recent)
        }, TIMEOUT_MS)
    }
}
