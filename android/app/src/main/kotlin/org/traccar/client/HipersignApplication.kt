package org.traccar.client

import android.app.Application

class HipersignApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Starts watching location on/off for as long as the app process is alive
        // (the tracking service keeps it alive while tracking is on).
        LocationGuard.start(this)
    }
}
