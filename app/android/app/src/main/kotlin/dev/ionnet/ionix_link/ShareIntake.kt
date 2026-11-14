package dev.ionnet.ionix_link

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Receives what other apps share to Ionix Link (ACTION_SEND / ACTION_SEND_MULTIPLE) and hands it to Dart on the
 * `dev.ionnet.ionix_link/share` channel.
 *
 * A share is described, not read: text and subject, or per file its uri, display name, size and type. The bytes
 * only move when Dart asks to `stage` a file, which copies the content:// stream into the app's cache (hashing it on
 * the way) so it can be read in chunks, and so a share survives the sender revoking its temporary uri grant. The
 * price is one temporary copy of the file; `clear` removes them when the sheet closes and at startup.
 *
 * A share is handed over once. [consume] only changes this process's copy of the intent, so an activity the system
 * recreates later (reopened from Recents after the process died, or after the task finished) gets the original share
 * intent back: one launched from history is ignored, and a recreated one finds the handled marker in its saved state.
 */
class ShareIntake : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener,
    ActivityPluginBinding.OnSaveInstanceStateListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var launchShare: Map<String, Any?>? = null
    private var launchWasShare = false
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val stageDir: File get() = File(context.cacheDir, "share")

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "dev.ionnet.ionix_link/share")
        channel.setMethodCallHandler(this)
        worker.execute { stageDir.deleteRecursively() }
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        binding.addOnSaveStateListener(this)
        val intent = binding.activity.intent
        launchWasShare = isShare(intent)
        val fromHistory = intent != null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        launchShare = if (fromHistory) null else describe(intent)
        consume(intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        binding.addOnSaveStateListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding?.removeOnSaveStateListener(this)
        binding = null
        activity = null
    }

    override fun onSaveInstanceState(bundle: Bundle) {
        if (launchWasShare) bundle.putBoolean(HANDLED_KEY, true)
    }

    // Called during onCreate, after onAttachedToActivity and before Dart can ask for the launch share.
    override fun onRestoreInstanceState(bundle: Bundle?) {
        if (bundle?.getBoolean(HANDLED_KEY) == true) {
            launchWasShare = true
            launchShare = null
        }
    }

    // A share while the app is already running (launchMode singleTop).
    override fun onNewIntent(intent: Intent): Boolean {
        val share = describe(intent) ?: return false
        consume(intent)
        channel.invokeMethod("share", share)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeLaunchShare" -> {
                result.success(launchShare)
                launchShare = null
            }
            "stage" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.error("bad_args", "stage needs a uri.", null)
                    return
                }
                worker.execute {
                    try {
                        val staged = stage(Uri.parse(uri))
                        main.post { result.success(staged) }
                    } catch (e: Exception) {
                        main.post { result.error("stage_failed", e.message ?: "Could not read the shared file.", null) }
                    }
                }
            }
            "clear" -> {
                worker.execute { stageDir.deleteRecursively() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Marks the intent as handled so recreating the activity does not share it a second time. */
    private fun consume(intent: Intent?) {
        if (intent != null && isShare(intent)) {
            intent.action = Intent.ACTION_MAIN
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.removeExtra(Intent.EXTRA_TEXT)
        }
    }

    private fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    /** The share an intent carries as a map for Dart, or null when it is not a share. */
    private fun describe(intent: Intent?): Map<String, Any?>? {
        if (intent == null || !isShare(intent)) return null
        val action = intent.action
        val uris = ArrayList<Uri>()
        if (action == Intent.ACTION_SEND) {
            streamExtra(intent)?.let { uris.add(it) }
        } else {
            streamListExtra(intent)?.let { uris.addAll(it) }
        }
        if (uris.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
            }
        }
        val files = uris.mapNotNull { fileInfo(it, intent.type) }
        return mapOf(
            "text" to if (files.isEmpty()) intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() else null,
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
            "files" to files,
        )
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    /** A file:// uri may name this app's own private files (keys, settings); never share those. */
    private fun isOwnPrivate(uri: Uri): Boolean {
        if (uri.scheme != "file") return false
        val path = uri.path ?: return true
        return try {
            File(path).canonicalPath.startsWith(File(context.applicationInfo.dataDir).canonicalPath)
        } catch (e: IOException) {
            true
        }
    }

    private fun fileInfo(uri: Uri, intentType: String?): Map<String, Any?>? {
        if (isOwnPrivate(uri)) return null
        var name: String? = null
        var size = -1L
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameAt = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeAt = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameAt >= 0 && !cursor.isNull(nameAt)) name = cursor.getString(nameAt)
                    if (sizeAt >= 0 && !cursor.isNull(sizeAt)) size = cursor.getLong(sizeAt)
                }
            }
        } catch (e: Exception) {
            // Not every provider answers a query; the name then comes from the uri and the size from the copy.
        }
        val type = context.contentResolver.getType(uri) ?: intentType
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "shared file"),
            "size" to size,
            "mime" to type,
        )
    }

    /** Copies [uri] into the cache and returns {path, size, sha256}. Runs on the worker thread. */
    private fun stage(uri: Uri): Map<String, Any?> {
        if (isOwnPrivate(uri)) throw IOException("That file belongs to this app and cannot be shared.")
        stageDir.mkdirs()
        val target = File.createTempFile("share-", ".bin", stageDir)
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        try {
            val input = context.contentResolver.openInputStream(uri) ?: throw IOException("The sharing app did not provide the file.")
            input.use { source ->
                target.outputStream().use { sink ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = source.read(buffer)
                        if (n < 0) break
                        sink.write(buffer, 0, n)
                        digest.update(buffer, 0, n)
                        size += n
                    }
                }
            }
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        return mapOf("path" to target.absolutePath, "size" to size, "sha256" to digest.digest().joinToString("") { "%02x".format(it) })
    }

    private companion object {
        const val HANDLED_KEY = "dev.ionnet.ionix_link.share_handled"
    }
}
