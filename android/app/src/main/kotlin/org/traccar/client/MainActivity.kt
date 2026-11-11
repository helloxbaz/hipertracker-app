package org.traccar.client

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // the trip screen asks for a floating window (picture-in-picture) when the app is left
    private var pipWanted = false
    private var pipChannel: MethodChannel? = null

    private fun pipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(3, 4))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(pipWanted).setSeamlessResizeEnabled(false)
        }
        return b.build()
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            enterPictureInPictureMode(pipParams()!!)
        } catch (e: Exception) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters by itself (auto-enter); older ones are sent here on the home button
        if (pipWanted && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("changed", isInPictureInPictureMode)
    }

    override fun onResume() {
        super.onResume()
        // the app is in the foreground here, so Android always allows the protection service to start
        LocationGuard.start(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.traccar.client/location_guard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> {
                        LocationGuard.check(applicationContext)
                        result.success(LocationGuard.currentState(applicationContext))
                    }
                    "setDuty" -> {
                        LocationGuard.setDuty(
                            applicationContext,
                            call.argument<Boolean>("dutyMode") ?: false,
                            call.argument<Boolean>("onDuty") ?: false,
                            call.argument<Int>("alarmInterval") ?: 30,
                            call.argument<Int>("escalateAfter") ?: 1,
                        )
                        result.success(LocationGuard.currentState(applicationContext))
                    }
                    "getLocation" -> CurrentLocation.get(applicationContext, result)
                    else -> result.notImplemented()
                }
            }
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.traccar.client/pip").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        pipWanted = call.arguments == true
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                setPictureInPictureParams(pipParams()!!)
                            } catch (e: Exception) {
                            }
                        }
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
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
