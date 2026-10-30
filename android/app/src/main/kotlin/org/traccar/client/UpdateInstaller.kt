package org.traccar.client

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** Own subclass so it can't clash with FileProviders declared by plugins. */
class UpdateFileProvider : FileProvider()

/**
 * Downloads a new HiperTracker APK and opens Android's installer for it.
 * Results sent back to Flutter: "installing", "permission" (user must allow installing
 * apps from HiperTracker first) or "error".
 */
object UpdateInstaller {

    private const val TAG = "UpdateInstaller"
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun install(activity: Activity, url: String, name: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + activity.packageName))
            try {
                activity.startActivity(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Could not open install permission screen", e)
            }
            result.success("permission")
            return
        }
        executor.execute {
            val outcome = try {
                val file = download(activity, url, name)
                main.post { openInstaller(activity, file, result) }
                null
            } catch (e: Exception) {
                Log.w(TAG, "Update download failed", e)
                "error"
            }
            if (outcome != null) main.post { result.success(outcome) }
        }
    }

    private fun download(activity: Activity, url: String, name: String): File {
        val dir = File(activity.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val target = File(dir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
        var current = URL(url)
        // GitHub release downloads redirect to a storage host, sometimes more than once
        repeat(5) {
            val conn = current.openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", "HiperTracker-App")
            try {
                val code = conn.responseCode
                if (code in 300..399) {
                    current = URL(current, conn.getHeaderField("Location"))
                    return@repeat
                }
                if (code != 200) throw IllegalStateException("HTTP $code")
                conn.inputStream.use { input -> target.outputStream().use { input.copyTo(it) } }
                return target
            } finally {
                conn.disconnect()
            }
        }
        throw IllegalStateException("Too many redirects")
    }

    private fun openInstaller(activity: Activity, file: File, result: MethodChannel.Result) {
        try {
            val uri = FileProvider.getUriForFile(activity, activity.packageName + ".updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success("installing")
        } catch (e: Exception) {
            Log.w(TAG, "Could not open installer", e)
            result.success("error")
        }
    }
}
