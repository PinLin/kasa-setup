plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // Use debug signing so `flutter run --release` works on a dev
            // machine without configuring a release keystore. Replace before
            // shipping anywhere real.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
