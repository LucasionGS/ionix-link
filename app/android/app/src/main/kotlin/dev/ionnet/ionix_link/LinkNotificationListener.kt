package dev.ionnet.ionix_link

import android.app.Notification
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Forwards the phone's notifications into Dart (see [PhoneNotifications]) so the desktop can show them
 * (PROTOCOL.md 8.10). Android binds it once the user has granted notification access; it forwards nothing while the
 * switch in Settings is off, and skips what a desktop has no use for.
 */
class LinkNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!PhoneNotifications.isEnabled(this) || skipped(sbn)) return
        val label = labelOf(sbn.packageName)
        PhoneNotifications.noteApp(this, sbn.packageName, label)
        if (!PhoneNotifications.isAllowed(this, sbn.packageName)) return
        val extras = sbn.notification.extras
        val title = (extras.getCharSequence(Notification.EXTRA_TITLE_BIG) ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        PhoneNotifications.emit(
            mapOf(
                "event" to "posted",
                "key" to sbn.key,
                "app" to sbn.packageName,
                "appName" to label,
                "title" to title,
                "text" to text,
                "time" to sbn.postTime,
                "silent" to isQuiet(sbn),
            )
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!PhoneNotifications.isEnabled(this) || skipped(sbn) || !PhoneNotifications.isAllowed(this, sbn.packageName)) return
        PhoneNotifications.emit(mapOf("event" to "removed", "key" to sbn.key))
    }

    /** Ongoing and foreground-service entries, group summaries, our own, and anything the lock screen hides. */
    private fun skipped(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName == packageName) return true
        val n = sbn.notification
        val flags = Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE or Notification.FLAG_GROUP_SUMMARY
        return n.flags and flags != 0 || n.visibility == Notification.VISIBILITY_SECRET
    }

    private fun isQuiet(sbn: StatusBarNotification): Boolean {
        val ranking = Ranking()
        val found = try {
            currentRanking.getRanking(sbn.key, ranking)
        } catch (e: RuntimeException) {
            false
        }
        return found && ranking.importance <= NotificationManager.IMPORTANCE_LOW
    }

    private fun labelOf(pkg: String): String {
        return try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            pkg
        }
    }

    companion object {
        @Volatile
        private var instance: LinkNotificationListener? = null

        /** Takes a notification off the phone because the user closed it on the desktop. Some cannot be cancelled. */
        fun cancel(key: String) {
            if (key.isEmpty()) return
            try {
                instance?.cancelNotification(key)
            } catch (e: SecurityException) {
                // Access was revoked after the service bound; nothing to cancel with.
            }
        }
    }
}
