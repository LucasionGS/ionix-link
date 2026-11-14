package dev.ionnet.ionix_link

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The phone's notifications on the desktop (PROTOCOL.md 8.10), the part that is not Dart: what the user chose,
 * the channels to Dart, and a short buffer for events that arrive while no Flutter engine is listening.
 *
 * The user's choices (the switch and the apps turned off) live here in SharedPreferences rather than in Dart, because
 * [LinkNotificationListener] filters with them before anything reaches Dart, and Android starts that service on its own.
 */
object PhoneNotifications {
    private const val METHODS = "dev.ionnet.ionix_link/phone_notifications"
    private const val EVENTS = "dev.ionnet.ionix_link/phone_notifications/events"
    private const val PREFS = "phone_notifications"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_BLOCKED = "blocked"
    private const val APPS = "phone_notification_apps"
    private const val BUFFER_MAX = 50
    private const val BUFFER_TTL_MS = 2 * 60 * 1000L

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val buffer = ArrayDeque<Pair<Long, Map<String, Any?>>>()

    /** Wires both channels to [engine]. One line in MainActivity.configureFlutterEngine. */
    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessGranted" -> result.success(isAccessGranted(app))
                "openAccessSettings" -> {
                    app.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "isEnabled" -> result.success(isEnabled(app))
                "setEnabled" -> {
                    setEnabled(app, call.arguments == true)
                    result.success(null)
                }
                "apps" -> result.success(apps(app))
                "setAppAllowed" -> {
                    setAppAllowed(app, call.argument<String>("package") ?: "", call.argument<Boolean>("allowed") == true)
                    result.success(null)
                }
                "cancel" -> {
                    LinkNotificationListener.cancel(call.arguments as? String ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                flush()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    /**
     * The engine is going away. A Dart isolate that dies with it never reaches `onCancel`, so without this the
     * dead sink would take the events that should wait in the buffer for the next start.
     */
    fun detach() {
        main.post { sink = null }
    }

    fun isAccessGranted(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
        return enabled.split(":").any { it.substringBefore("/") == context.packageName }
    }

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    private fun setEnabled(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, on).apply()
        if (!on) main.post { buffer.clear() }
    }

    fun isAllowed(context: Context, pkg: String): Boolean = !(prefs(context).getStringSet(KEY_BLOCKED, emptySet()) ?: emptySet()).contains(pkg)

    private fun setAppAllowed(context: Context, pkg: String, allowed: Boolean) {
        if (pkg.isEmpty()) return
        val blocked = (prefs(context).getStringSet(KEY_BLOCKED, emptySet()) ?: emptySet()).toMutableSet()
        if (allowed) blocked.remove(pkg) else blocked.add(pkg)
        prefs(context).edit().putStringSet(KEY_BLOCKED, blocked).apply()
    }

    /** Remembers that [pkg] has posted, so the settings page can list it. */
    fun noteApp(context: Context, pkg: String, label: String) {
        val store = context.getSharedPreferences(APPS, Context.MODE_PRIVATE)
        if (store.getString(pkg, null) != label) store.edit().putString(pkg, label).apply()
    }

    private fun apps(context: Context): List<Map<String, Any?>> {
        val store = context.getSharedPreferences(APPS, Context.MODE_PRIVATE)
        return store.all.mapNotNull { (pkg, label) -> (label as? String)?.let { Triple(pkg, it, isAllowed(context, pkg)) } }
            .sortedBy { it.second.lowercase() }
            .map { mapOf("package" to it.first, "name" to it.second, "allowed" to it.third) }
    }

    /**
     * Hands an event to Dart on the main thread, or keeps it for [BUFFER_TTL_MS] when no engine is listening (the
     * app was swiped away while the listener lives on). It never grows past [BUFFER_MAX].
     */
    fun emit(event: Map<String, Any?>) {
        main.post {
            val target = sink
            if (target != null) {
                target.success(event)
                return@post
            }
            buffer.addLast(System.currentTimeMillis() to event)
            while (buffer.size > BUFFER_MAX) buffer.removeFirst()
        }
    }

    private fun flush() {
        val target = sink ?: return
        val now = System.currentTimeMillis()
        while (buffer.isNotEmpty()) {
            val (at, event) = buffer.removeFirst()
            if (now - at <= BUFFER_TTL_MS) target.success(event)
        }
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
