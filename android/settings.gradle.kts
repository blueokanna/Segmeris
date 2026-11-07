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
    id("com.android.application") version "9.1.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Stable WebView 1.1.3 still requests the ProGuard file removed in AGP 9.
findProject(":flutter_inappwebview_android")?.let { webView ->
    val source = File(webView.projectDir, "build.gradle").readText()
    val legacyRule = "getDefaultProguardFile('proguard-android.txt')"
    check(source.split(legacyRule).size == 3) {
        "WebView build script changed; review and remove its AGP 9 compatibility patch."
    }
    val patched = source.replace(
        legacyRule, "getDefaultProguardFile('proguard-android-optimize.txt')"
    )
    val stagedProject = File(rootDir.parentFile, "build/plugin-gradle/flutter_inappwebview_android")
    webView.projectDir.walkTopDown()
        .onEnter { it.name !in setOf("build", ".gradle") }
        .filter { it.isFile && it.name != "build.gradle" }
        .forEach { original ->
            val target = File(stagedProject, original.relativeTo(webView.projectDir).path)
            val content = original.readBytes()
            if (!target.exists() || !target.readBytes().contentEquals(content)) {
                target.parentFile.mkdirs()
                target.writeBytes(content)
            }
        }
    val buildScript = File(stagedProject, "build.gradle")
    buildScript.parentFile.mkdirs()
    if (!buildScript.exists() || buildScript.readText() != patched) {
        buildScript.writeText(patched)
    }
    webView.projectDir = stagedProject
}
