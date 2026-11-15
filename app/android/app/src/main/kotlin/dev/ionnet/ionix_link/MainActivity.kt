package dev.ionnet.ionix_link

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ShareIntake())
        PhoneNotifications.register(this, flutterEngine)
        VideoDecoders.register(flutterEngine)
        // Keeps the screen awake while the touchpad or the screen view is open (ScreenAwake in lib/ui/sources.dart).
        // The flag belongs to this window, so the phone still sleeps normally once the app is left.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.ionnet.ionix_link/window").setMethodCallHandler { call, result ->
            when (call.method) {
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        PhoneNotifications.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
