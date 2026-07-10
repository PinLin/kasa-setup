import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials live outside the repo (android/key.properties, gitignored).
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "me.pinlin.kasa_setup"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        // Required since AGP 8: BuildConfig generation is opt-in. Needed so
        // MainActivity can pass BuildConfig.VERSION_CODE to FreeDroidWarn.
        buildConfig = true
    }

    defaultConfig {
        applicationId = "me.pinlin.kasa_setup"
        // WifiNetworkSpecifier was added in API 29 (Android 10). The whole
        // app design assumes that path, so we floor here rather than try to
        // ship a legacy WifiManager.enableNetwork() fallback.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pinned (not V1.+) per repo policy: see https://github.com/woheller69/FreeDroidWarn tags.
    implementation("com.github.woheller69:FreeDroidWarn:V1.13")
}
