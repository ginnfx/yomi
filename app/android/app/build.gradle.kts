import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Installed copies only accept updates signed with this same key, so a release
// build must never fall back to the debug key. See app/README.md, "Releasing".
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = !keyProperties.getProperty("storeFile").isNullOrBlank()
val isReleaseBuild = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (isReleaseBuild && !hasReleaseKey) {
    throw GradleException("Release builds need android/key.properties. See app/README.md, \"Releasing\".")
}

android {
    namespace = "com.yomi.yomi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yomi.yomi"
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
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    // youtubedl-android runs its bundled Python from the native library folder.
    packaging {
        jniLibs.useLegacyPackaging = true
        // Python and its libraries ship as zip files named .so; stripping can't read them.
        jniLibs.keepDebugSymbols += "**/*.zip.so"
    }

    buildTypes {
        // `--android-project-arg yomiSideBySide=true` installs a debug build beside the
        // real app, so device tests don't replace (or need to uninstall) it.
        debug {
            if (project.hasProperty("yomiSideBySide")) applicationIdSuffix = ".sidebyside"
        }
        release {
            if (hasReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core:1.16.0")
    // yt-dlp with its own Python, for playing and saving songs from YouTube.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    // Built by tailscale_bridge/build.sh; not committed because of its size.
    implementation(files("../../../tailscale_bridge/build/tailscale_bridge.aar"))
}
