package me.pinlin.kasa_setup

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * FlutterPlugin entry point for the Kasa setup MethodChannel.
 *
 * Wires the MethodChannel `kasa_setup/wifi` to the [WifiBinder] logic and,
 * critically, releases the active [WifiBinder] reservation from
 * [onDetachedFromEngine]. That fires on Flutter hot-restart and on engine
 * teardown — without it, hot-restarting while joined to the Kasa AP leaves
 * the phone stranded on the device hotspot until the user toggles Wi-Fi.
 *
 * Application-Context-scoped: every operation goes through Wi-Fi system
 * services and Settings intents (`FLAG_ACTIVITY_NEW_TASK`) that work from
 * an application context, so no Activity binding is required.
 */
class KasaSetupPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        private const val CHANNEL = "kasa_setup/wifi"
    }

    private lateinit var channel: MethodChannel
    private var binder: WifiBinder? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        binder = WifiBinder(ctx)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Best-effort cleanup — release any active network binding so we
        // don't leave the phone stranded on a Kasa AP after hot-restart.
        binder?.leave()
        binder = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val b = binder ?: run {
            result.error("UNKNOWN", "plugin not attached", null)
            return
        }
        when (call.method) {
            "joinOpenAp" -> {
                val ssid = call.argument<String>("ssid")
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 30_000
                if (ssid == null) {
                    result.error("ARG", "ssid required", null)
                } else {
                    b.joinOpenAp(ssid, timeoutMs.toLong()) { ok, code, msg ->
                        if (ok) result.success(null)
                        else result.error(code, msg, null)
                    }
                }
            }
            "leave" -> {
                b.leave()
                result.success(null)
            }
            "currentBoundSsid" -> {
                result.success(b.currentBoundSsid())
            }
            "scanKasaSsids" -> {
                b.scanKasaSsids { ssids -> result.success(ssids) }
            }
            "scan24GhzNetworks" -> {
                b.scan24GhzNetworks { networks -> result.success(networks) }
            }
            "bindToCurrentApIfKasa" -> {
                b.bindToCurrentApIfKasa { ok, code, msg ->
                    if (ok) result.success(msg) // msg carries the SSID on success
                    else result.error(code, msg, null)
                }
            }
            "ensureJoinedAp" -> {
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 30_000
                b.ensureJoinedAp(timeoutMs.toLong()) { ok, code, msg ->
                    if (ok) result.success(msg) // msg carries the SSID on success
                    else result.error(code, msg, null)
                }
            }
            "openWifiSettings" -> {
                b.openWifiSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
