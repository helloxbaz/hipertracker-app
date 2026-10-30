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
    }
}
