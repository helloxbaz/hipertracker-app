package org.traccar.client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.traccar.client/location_guard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> {
                        LocationGuard.check(applicationContext)
                        result.success(LocationGuard.currentState(applicationContext))
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.traccar.client/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.success("error")
                        } else {
                            UpdateInstaller.install(this, url, call.argument<String>("name") ?: "HiperTracker.apk", result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
