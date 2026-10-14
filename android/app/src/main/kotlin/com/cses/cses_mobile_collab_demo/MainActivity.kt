package com.cses.cses_mobile_collab_demo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Common 的完整设备初始化需要设备 ID、CPU 型号和 getCpuInfo。
        // 处理器沿用 CSES Android 宿主的通道契约；CPU 读取失败由系统信息兜底，
        // Dart 仍统一调用 ctx.updateDeviceInfo，不再维护 demo 专属占位设备信息。
        val deviceInfo = DeviceInfoMethodHandler(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.yundiz/common")
            .setMethodCallHandler { call, result ->
                if (!deviceInfo.handle(call, result)) result.notImplemented()
            }
    }
}
