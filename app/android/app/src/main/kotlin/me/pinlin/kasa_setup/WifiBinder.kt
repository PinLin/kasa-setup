package me.pinlin.kasa_setup

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Joins an open Wi-Fi AP and binds the whole process to that network so all
 * Dart-side socket I/O is routed through the AP interface (and not, e.g., back
 * over cellular when Android decides the AP "has no internet").
 *
 * Reverses on `leave()`, releasing the network back to the OS so the user's
 * preferred home Wi-Fi takes over.
 */
class WifiBinder(private val ctx: Context) {

    private val cm: ConnectivityManager =
        ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi: WifiManager =
        ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())

    private var current: ConnectivityManager.NetworkCallback? = null
    /** Last AP SSID we successfully joined — kept across onLost so we can
     *  transparently re-join if Android drops the link while the user is on
     *  the credentials screen. Cleared only by [leave]. */
    private var apSsid: String? = null
    /** Currently-bound AP Network handle, or null if the link has been lost
     *  (or we never joined). Distinct from [apSsid] so we can tell "binding
     *  alive, just re-pin" from "binding gone, must re-request". */
    private var apNetwork: Network? = null

    /**
     * Build a NetworkRequest for [ssid] (open) and call back with success once
     * the system reports the network is available, or with an error after
     * [timeoutMs].
     */
    fun joinOpenAp(
        ssid: String,
        timeoutMs: Long,
        onResult: (ok: Boolean, code: String, msg: String) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onResult(false, "UNSUPPORTED", "This app requires Android 10 (API 29) or higher.")
            return
        }
        // Tear down any previous request; preserve apSsid only if it's the same.
        leaveInternal(rememberSsid = ssid)

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            // open AP — no key set
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var done = false

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                apNetwork = network
                cm.bindProcessToNetwork(network)
                if (done) return
                done = true
                apSsid = ssid
                onResult(true, "", "")
            }
            override fun onUnavailable() {
                if (done) return
                done = true
                onResult(false, "UNAVAILABLE", "Could not join the device hotspot.")
            }
            override fun onLost(network: Network) {
                // Drop binding so home-WiFi traffic isn't accidentally routed
                // through a dead AP socket, but keep apSsid so ensureJoinedAp
                // can re-acquire on the next provision attempt.
                if (apNetwork == network) {
                    apNetwork = null
                    cm.bindProcessToNetwork(null)
                }
            }
        }
        current = cb
        cm.requestNetwork(request, cb, timeoutMs.toInt().coerceAtLeast(5_000))

        main.postDelayed({
            if (!done) {
                done = true
                onResult(false, "TIMEOUT", "Timed out waiting for the device hotspot.")
            }
        }, timeoutMs)
    }

    /**
     * Make sure the process is currently routed through the previously-joined
     * Kasa AP. Cheap if still bound; if Android dropped the network (typical
     * after ~30s of user typing on the credentials screen), transparently
     * re-issues `requestNetwork`. The system caches recent user approval for
     * the same SSID, so the dialog usually does not re-prompt.
     */
    fun ensureJoinedAp(
        timeoutMs: Long,
        onResult: (ok: Boolean, code: String, msg: String) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onResult(false, "UNSUPPORTED", "Android 10+ required.")
            return
        }
        val net = apNetwork
        if (net != null) {
            // Still bound — re-pin defensively (cheap no-op if already pinned).
            // Validate the Network is alive though; in the manual-join path
            // there is no NetworkCallback to clear apNetwork when the link
            // drops, so the handle may be stale.
            if (cm.getNetworkCapabilities(net) != null) {
                cm.bindProcessToNetwork(net)
                onResult(true, "", apSsid ?: "")
                return
            }
            apNetwork = null
        }
        val ssid = apSsid
        if (ssid == null) {
            onResult(false, "NO_SSID", "No Kasa AP has been joined in this session.")
            return
        }
        joinOpenAp(ssid, timeoutMs, onResult)
    }

    fun leave() = leaveInternal(rememberSsid = null)

    private fun leaveInternal(rememberSsid: String?) {
        cm.bindProcessToNetwork(null)
        current?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) {}
        }
        current = null
        apNetwork = null
        apSsid = rememberSsid
    }

    fun currentBoundSsid(): String? {
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        val raw = info.ssid ?: return null
        return raw.trim('"').takeIf { it.isNotBlank() && it != "<unknown ssid>" }
    }

    /**
     * Scan for nearby Wi-Fi APs and return the SSIDs that look like a fresh
     * Kasa device (HS300 power strip, HS100/110 plug, etc).
     *
     * Requires Wi-Fi scan permission already granted on the Dart side.
     */
    fun scanKasaSsids(onResult: (List<String>) -> Unit) {
        scanWifi(::filterKasaSsids, onResult)
    }

    private fun filterKasaSsids(): List<String> {
        @Suppress("DEPRECATION")
        val results = try { wifi.scanResults ?: emptyList() } catch (_: SecurityException) { emptyList() }
        return results
            .map { it.SSID }
            .filterNotNull()
            .filter { looksLikeKasaAp(it) }
            .distinct()
    }

    /**
     * Scan nearby 2.4 GHz APs (excluding Kasa device APs) and return a list of
     * `{ssid, signal, secured}` maps sorted by signal strength. Used to populate
     * the home Wi-Fi SSID picker so the user doesn't have to type it.
     */
    fun scan24GhzNetworks(onResult: (List<Map<String, Any?>>) -> Unit) {
        scanWifi(::filter24GhzNetworks, onResult)
    }

    /**
     * Run a single Wi-Fi scan and dispatch results through [extract] exactly
     * once — even if both the broadcast receiver and the hard timeout fire.
     * Double-dispatch causes `Reply already submitted` on the MethodChannel.
     */
    private fun <T> scanWifi(
        extract: () -> T,
        onResult: (T) -> Unit,
    ) {
        var done = false
        val safe: () -> Unit = {
            if (!done) {
                done = true
                onResult(extract())
            }
        }
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                try { ctx.unregisterReceiver(this) } catch (_: Exception) {}
                safe()
            }
        }
        try {
            ctx.registerReceiver(receiver, filter)
        } catch (_: Exception) {
            safe()
            return
        }

        @Suppress("DEPRECATION")
        val started = wifi.startScan()
        if (!started) {
            // Some OEMs throttle startScan(). Fall back to whatever cache we have.
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
            safe()
            return
        }

        // Hard timeout in case the scan-results broadcast never arrives.
        main.postDelayed({
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
            safe()
        }, 8_000)
    }

    /** Open the Android system Wi-Fi settings page so the user can manually
     *  join the device's open AP. Returns immediately. */
    fun openWifiSettings() {
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }

    private fun filter24GhzNetworks(): List<Map<String, Any?>> {
        @Suppress("DEPRECATION")
        val results = try { wifi.scanResults ?: emptyList() } catch (_: SecurityException) { emptyList() }
        return results
            .filter { it.frequency in 2400..2500 }
            .filter { !it.SSID.isNullOrBlank() && it.SSID != "<unknown ssid>" }
            .filter { !looksLikeKasaAp(it.SSID) }
            .filter {
                // HS300 only speaks WPA / WPA2. Pure-WPA3 networks (no
                // WPA2 transition) advertise `SAE` (WPA3-PSK) or `OWE`
                // (WPA3 Enhanced Open) WITHOUT a `WPA` substring. WPA2/WPA3
                // transition-mode APs advertise both `WPA2` and `SAE`, so
                // we keep those — the HS300 will negotiate down to WPA2.
                val cap = it.capabilities ?: ""
                val pureWpa3 =
                    (cap.contains("SAE") || cap.contains("OWE")) &&
                            !cap.contains("WPA")
                !pureWpa3
            }
            .distinctBy { it.SSID }
            .sortedByDescending { it.level }
            .map { sr ->
                val cap = sr.capabilities ?: ""
                // SAE present here means WPA2/WPA3 transition mode (filtered
                // pure-WPA3 above). Treat as secured.
                val secured = cap.contains("WPA") ||
                        cap.contains("WEP") ||
                        cap.contains("EAP") ||
                        cap.contains("SAE")
                mapOf(
                    "ssid" to sr.SSID,
                    "signal" to sr.level,
                    "secured" to secured,
                )
            }
    }

    private fun looksLikeKasaAp(ssid: String): Boolean {
        val s = ssid.lowercase()
        return s.startsWith("tp-link_smart plug_") ||
            s.startsWith("tp-link_power strip_") ||
            s.startsWith("kasa_smart plug_")
    }

    /**
     * If the phone is already connected to a Kasa device AP (because the user
     * joined it manually in Android Settings, for example), bind the process to
     * that Wi-Fi network so socket I/O routes through it — without invoking
     * `WifiNetworkSpecifier`, which would re-prompt the user.
     *
     * Reports success only when the current Wi-Fi SSID matches a Kasa pattern.
     */
    fun bindToCurrentApIfKasa(
        onResult: (ok: Boolean, code: String, msg: String) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onResult(false, "UNSUPPORTED", "Android 10+ required.")
            return
        }
        val ssid = currentBoundSsid()
        if (ssid == null) {
            onResult(false, "NO_WIFI", "Phone is not on a Wi-Fi network.")
            return
        }
        if (!looksLikeKasaAp(ssid)) {
            onResult(false, "NOT_KASA", ssid)
            return
        }
        val wifiNet = cm.allNetworks.firstOrNull { net ->
            val caps = cm.getNetworkCapabilities(net) ?: return@firstOrNull false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        }
        if (wifiNet == null) {
            onResult(false, "NO_NETWORK", "Wi-Fi network not enumerable.")
            return
        }
        cm.bindProcessToNetwork(wifiNet)
        // Save state so ensureJoinedAp can recover the binding later if the
        // user-manual-join path is what got us onto the AP.
        apNetwork = wifiNet
        apSsid = ssid
        onResult(true, "", ssid)
    }
}
