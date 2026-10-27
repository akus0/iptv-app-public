import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local signing credentials are read only by Gradle, never bundled as app assets.
// Environment variables take precedence for CI. Fresh clones can use debug signing.
val localEnvironment = Properties()
val localEnvironmentFile = rootProject.file("../.env")
if (localEnvironmentFile.exists()) {
    localEnvironmentFile.inputStream().use { localEnvironment.load(it) }
}
fun localSetting(name: String): String? =
    (System.getenv(name) ?: localEnvironment.getProperty(name))?.takeIf { it.isNotBlank() }
val signingFile = localSetting("ANDROID_KEYSTORE_FILE")
val signingStorePassword = localSetting("ANDROID_KEYSTORE_PASSWORD")
val signingAlias = localSetting("ANDROID_KEY_ALIAS")
val signingKeyPassword = localSetting("ANDROID_KEY_PASSWORD")
val signingValues = listOf(signingFile, signingStorePassword, signingAlias, signingKeyPassword)
val hasReleaseKeystore = signingValues.all { it != null }
require(signingValues.all { it == null } || hasReleaseKeystore) {
    "Release signing configuration is incomplete. Check the ANDROID_KEYSTORE settings."
}

android {
    namespace = "com.nox.nox_iptv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep stable so existing installations can update without losing data.
        applicationId = "com.akus0.iptvpreview"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(signingFile!!)
                storePassword = signingStorePassword
                keyAlias = signingAlias
                keyPassword = signingKeyPassword
            }
        }
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    buildTypes {
        debug {
            // Install debug builds beside release builds with separate app data.
            applicationIdSuffix = ".debug"
        }
        release {
            // Distribution builds must use the configured release certificate.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Flutter's default ABI filter includes every supported CPU even when a build
// requests fewer targets. Keep plugin libraries aligned with the app runtime.
androidComponents.finalizeDsl { dsl ->
    if (!dsl.splits.abi.isEnable) {
        val requestedTargets = project.findProperty("target-platform")?.toString()?.split(",")
        val abiByTarget = mapOf(
            "android-arm" to "armeabi-v7a",
            "android-arm64" to "arm64-v8a",
            "android-x64" to "x86_64",
        )
        if (requestedTargets != null) {
            val requestedAbis = requestedTargets.map { target ->
                requireNotNull(abiByTarget[target.trim()]) { "Unsupported Android target: $target" }
            }
            dsl.defaultConfig.ndk.abiFilters.clear()
            dsl.defaultConfig.ndk.abiFilters.addAll(requestedAbis)
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
}

// AGP's host-test packaging also consumes the assets supplied by Flutter.
tasks.matching { it.name == "packageDebugUnitTestForUnitTest" }.configureEach {
    dependsOn("copyFlutterAssetsDebug")
}
