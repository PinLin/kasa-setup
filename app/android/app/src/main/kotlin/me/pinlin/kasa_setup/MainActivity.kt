package me.pinlin.kasa_setup

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.woheller69.freeDroidWarn.FreeDroidWarn

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // One-time notice shown again whenever versionCode increases.
        FreeDroidWarn.showWarningOnUpgrade(this, BuildConfig.VERSION_CODE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Channel and WifiBinder lifecycle live in KasaSetupPlugin so
        // onDetachedFromEngine (fires on hot-restart and engine teardown)
        // gets a chance to call binder.leave() — without this the phone
        // stays stranded on the Kasa AP after a debug hot-restart.
        flutterEngine.plugins.add(KasaSetupPlugin())
    }
}
