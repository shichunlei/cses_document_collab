package com.cses.cses_mobile_collab_demo

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // cses.common 的 DeviceUtils 通过此宿主通道读取 Android 设备标识。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.yundiz/common")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceId" -> result.success(
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
