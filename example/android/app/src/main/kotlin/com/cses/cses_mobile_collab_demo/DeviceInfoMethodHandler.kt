package com.cses.cses_mobile_collab_demo

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.FileReader

/// Android 设备与 CPU 信息方法处理器。
///
/// 该处理器仅响应 `com.yundiz/common` 中的设备查询方法。读取 `/proc/cpuinfo`
/// 失败时返回稳定的系统兜底信息，避免硬件差异影响 Flutter 页面初始化。
internal class DeviceInfoMethodHandler(private val context: Context) {
    private companion object {
        private const val TAG = "DeviceInfoHandler"
        private const val CPU_INFO_PATH = "/proc/cpuinfo"
    }

    /// 处理设备信息相关的平台方法。
    ///
    /// [call] 是 Flutter 发起的方法调用，[result] 用于返回平台结果。
    /// 返回 `true` 表示方法已处理，返回 `false` 表示应由其他业务处理器继续匹配。
    @SuppressLint("HardwareIds")
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "getCpuModel" -> result.success(getCpuModel())
            "getCpuArch" -> result.success(Build.SUPPORTED_ABIS.joinToString(","))
            "getCpuCoreCount" -> result.success(Runtime.getRuntime().availableProcessors())
            "getCpuInfo" -> result.success(getCpuInfo())
            "getDeviceId" -> {
                val deviceId = Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ANDROID_ID
                )
                result.success(deviceId)
            }

            else -> return false
        }
        return true
    }

    /// 读取 CPU 型号，读取失败或设备未暴露字段时使用 [Build.HARDWARE]。
    private fun getCpuModel(): String {
        return try {
            BufferedReader(FileReader(CPU_INFO_PATH)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val currentLine = line.orEmpty()
                    if (currentLine.contains("Hardware") || currentLine.contains("model name")) {
                        return currentLine.substringAfter(":", Build.HARDWARE).trim()
                    }
                }
                Build.HARDWARE
            }
        } catch (error: Exception) {
            Log.e(TAG, "read CPU model failed", error)
            Build.HARDWARE
        }
    }

    /// 汇总 CPU 架构、ARM 指令集版本、ABI 与特性信息。
    private fun getCpuInfo(): Map<String, Any> {
        var architecture = ""
        var features = ""

        try {
            BufferedReader(FileReader(CPU_INFO_PATH)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val currentLine = line.orEmpty()
                    if (currentLine.startsWith("CPU architecture")) {
                        architecture = currentLine.substringAfter(":").trim()
                    }
                    if (currentLine.startsWith("Features")) {
                        features = currentLine.substringAfter(":").trim()
                    }
                }
            }
        } catch (error: Exception) {
            // 部分厂商会限制 /proc/cpuinfo；ABI 仍可让 Dart 侧判断 32/64 位，
            // 因此这里只记录异常，不把设备信息查询升级为平台通道错误。
            Log.e(TAG, "read CPU info failed", error)
        }

        return mapOf(
            "architecture" to architecture,
            "armVersion" to detectArmVersion(features),
            "isArm64" to Build.SUPPORTED_ABIS.contains("arm64-v8a"),
            "features" to features,
            "abis" to Build.SUPPORTED_ABIS.toList()
        )
    }

    /// 根据 CPU features 推断当前 ARM 指令集版本。
    ///
    /// [features] 为空或未包含高版本特征时保持既有行为，返回 `ARMv8.0`。
    private fun detectArmVersion(features: String): String {
        if (features.contains("sve2")) return "ARMv9"
        if (features.contains("i8mm") || features.contains("bf16") || features.contains("dgh")) {
            return "ARMv8.6"
        }
        if (features.contains("bti")) return "ARMv8.5"
        if (features.contains("asimddp")) return "ARMv8.4"
        if (features.contains("paca") || features.contains("pacg")) return "ARMv8.3"
        if (
            features.contains("fphp") ||
            features.contains("sha3") ||
            features.contains("sha512")
        ) {
            return "ARMv8.2"
        }
        if (features.contains("atomics")) return "ARMv8.1"
        return "ARMv8.0"
    }
}
