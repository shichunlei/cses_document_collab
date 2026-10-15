pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.2" apply false
    // Kotlin 2.3.20 是 Flutter 3.44.9 当前模板基线，并完整覆盖现用
    // AGP 8.13.2；后续切换 AGP 9.0 时也无需再次跨 Kotlin 大版本。
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
