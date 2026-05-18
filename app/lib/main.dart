import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'kasa/discovery.dart';
import 'kasa/protocol.dart';
import 'platform/platform_exception_codes.dart';
import 'platform/wifi_binder.dart';
import 'platform/wifi_binder_factory.dart';

void main() => runApp(const KasaSetupApp());

class KasaSetupApp extends StatelessWidget {
  const KasaSetupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kasa Setup',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
      ),
      themeMode: ThemeMode.system,
      home: const SetupHomeScreen(),
    );
  }
}

// ---- state machine ---------------------------------------------------------

enum SetupStep {
  intro,
  awaitDevice,
  pickHomeWifi,
  sendingCredentials,
  waitingForJoin,
  discoveringOnHomeWifi,
  done,
  error,
}

class SetupHomeScreen extends StatefulWidget {
  /// Production constructor — starts at [SetupStep.intro] and walks the user
  /// through the real flow.
  const SetupHomeScreen({super.key})
      : debugInitialStep = null,
        debugKasaApSsid = null,
        debugHomeNetworks = const [],
        debugDiscovered = null,
        debugError = null;

  /// Debug constructor used by golden tests to render any state directly.
  @visibleForTesting
  const SetupHomeScreen.preview({
    super.key,
    required SetupStep this.debugInitialStep,
    this.debugKasaApSsid,
    this.debugHomeNetworks = const [],
    this.debugDiscovered,
    this.debugError,
  });

  final SetupStep? debugInitialStep;
  final String? debugKasaApSsid;
  final List<WifiNetwork> debugHomeNetworks;
  final DiscoveredKasaDevice? debugDiscovered;
  final String? debugError;

  @override
  State<SetupHomeScreen> createState() => _SetupHomeScreenState();
}

class _SetupHomeScreenState extends State<SetupHomeScreen> {
  late SetupStep _step;
  String? _error;

  // Lazy so tests / debug previews don't try to attach a real MethodChannel.
  WifiBinder get _binder => _wifiBinder ??= createWifiBinder();
  WifiBinder? _wifiBinder;

  // The Kasa device AP SSID the phone is confirmed-joined to. Set ONLY when
  // we've verified the bound SSID matches a Kasa AP pattern (either via the
  // `_joinKasaAp` success branch or via `_checkApOnce` matching). Consumed by
  // `_pickHomeWifi` so the picker label always names the actual device AP.
  String? _kasaApSsid;

  // Whatever SSID the phone is currently bound to, regardless of whether it
  // is a Kasa AP. Updated by the `_checkApOnce` poller purely for the grey
  // "Phone is currently on '<ssid>'" footer in the awaitDevice view.
  String? _currentBoundSsid;

  // 2.4 GHz networks seen nearby — pre-warmed at intro so the picker
  // populates instantly when the user reaches pickHomeWifi.
  List<WifiNetwork> _homeNetworks = const [];
  bool _scanningHomeNetworks = false;

  // user-chosen home Wi-Fi (either from the picker or manual entry)
  WifiNetwork? _selectedHomeNetwork;
  bool _manualSsidMode = false;
  // One-shot guard: flipped true the first time the home-Wi-Fi scan returns
  // empty so we auto-switch into manual-SSID mode (broadlink-re behavior).
  // Without the guard, a successful follow-up scan would fight the user and
  // flip them back to the list view.
  bool _autoSwitchedToManual = false;
  final _manualSsidCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  int _keyType = 3; // WPA2 default
  bool _showPassword = false;

  // poller while in awaitDevice state
  Timer? _apPoller;

  // Kasa device APs detected by scan in awaitDevice
  List<String> _kasaApsFound = const [];
  bool _scanningKasaAps = false;
  String? _joiningKasaAp;
  String? _joinError;

  // result
  DiscoveredKasaDevice? _discovered;

  @override
  void initState() {
    super.initState();
    _step = widget.debugInitialStep ?? SetupStep.intro;
    _homeNetworks = widget.debugHomeNetworks;
    _kasaApSsid = widget.debugKasaApSsid;
    _discovered = widget.debugDiscovered;
    _error = widget.debugError;
  }

  @override
  void dispose() {
    _manualSsidCtl.dispose();
    _passwordCtl.dispose();
    _apPoller?.cancel();
    _apPoller = null;
    _binder.leave();
    super.dispose();
  }

  // ---- transitions ---------------------------------------------------------

  Future<void> _start() async {
    if (!await _ensurePermissions()) {
      _showError(
        'Location + nearby Wi-Fi permissions are required to scan and join networks. '
        'Open Settings → Apps → Kasa Setup → Permissions, allow both, then tap Start over.',
      );
      return;
    }
    // Reach awaitDevice BEFORE kicking off the scans — `_scanKasaAps` guards
    // its auto-join branch on `_step == SetupStep.awaitDevice`. If the scan
    // completes before the setState microtask flushes (slow emulator /
    // instrumentation), the auto-join is silently skipped.
    setState(() => _step = SetupStep.awaitDevice);
    // Warm the 2.4 GHz scan cache so pickHomeWifi populates instantly.
    unawaited(_refreshHomeNetworks());
    unawaited(_scanKasaAps());
    _startApPolling();
  }

  Future<void> _scanKasaAps() async {
    if (!mounted) return;
    setState(() => _scanningKasaAps = true);
    try {
      final found = await _binder.scanKasaSsids();
      if (!mounted) return;
      setState(() => _kasaApsFound = found);
      // If we see exactly one candidate and we're not already joining/joined,
      // kick off auto-join. Android still shows a system confirm dialog, but
      // the user only has to tap "Connect" once instead of going to Settings.
      if (found.length == 1 &&
          _joiningKasaAp == null &&
          _step == SetupStep.awaitDevice) {
        await _joinKasaAp(found.first);
      }
    } finally {
      if (mounted) setState(() => _scanningKasaAps = false);
    }
  }

  Future<void> _joinKasaAp(String ssid) async {
    if (!mounted) return;
    setState(() {
      _joiningKasaAp = ssid;
      _joinError = null;
    });
    try {
      await _binder.joinOpenAp(ssid);
      if (!mounted) return;
      _apPoller?.cancel();
      _apPoller = null;
      unawaited(_refreshHomeNetworks());
      setState(() {
        _kasaApSsid = ssid;
        _joiningKasaAp = null;
        _step = SetupStep.pickHomeWifi;
      });
    } on WifiBinderException catch (e) {
      if (!mounted) return;
      setState(() {
        _joiningKasaAp = null;
        _joinError = _describeError(e);
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _joiningKasaAp = null;
        _joinError = e.toString();
      });
    }
  }

  Future<bool> _ensurePermissions() async {
    final loc = await Permission.locationWhenInUse.request();
    final near = await Permission.nearbyWifiDevices.request();
    return loc.isGranted && (near.isGranted || near.isLimited);
  }

  void _startApPolling() {
    _apPoller?.cancel();
    _apPoller = null;
    _checkApOnce(); // immediate check
    _apPoller = Timer.periodic(const Duration(seconds: 3), (_) => _checkApOnce());
  }

  Future<void> _checkApOnce() async {
    if (_step != SetupStep.awaitDevice) {
      _apPoller?.cancel();
      _apPoller = null;
      return;
    }
    final ssid = await _binder.currentBoundSsid();
    if (!mounted) return;
    if (ssid != null && _looksLikeKasaAp(ssid)) {
      _apPoller?.cancel();
      _apPoller = null;
      // Bind the process to the Wi-Fi network so sockets go out via the AP.
      try {
        await _binder.bindToCurrentApIfKasa();
      } on Exception {
        // If binding fails, still try to proceed — discovery may still work.
      }
      // Re-scan now that we'd otherwise be cut off from home Wi-Fi visibility;
      // most Android implementations still let scanResults read from cache.
      unawaited(_refreshHomeNetworks());
      if (!mounted) return;
      setState(() {
        _kasaApSsid = ssid;
        _currentBoundSsid = ssid;
        _step = SetupStep.pickHomeWifi;
      });
    } else {
      // Just update the displayed "currently on" line — do NOT overload
      // `_kasaApSsid` here, otherwise downstream views would show a wrong
      // device-AP label if the user roamed off mid-flow.
      setState(() => _currentBoundSsid = ssid);
    }
  }

  static bool _looksLikeKasaAp(String ssid) {
    final s = ssid.toLowerCase();
    return s.startsWith('tp-link_smart plug_') ||
        s.startsWith('tp-link_power strip_') ||
        s.startsWith('kasa_smart plug_');
  }

  Future<void> _refreshHomeNetworks() async {
    if (!mounted) return;
    setState(() => _scanningHomeNetworks = true);
    try {
      final found = await _binder.scan24GhzNetworks();
      if (!mounted) return;
      setState(() {
        _homeNetworks = found;
        // Auto-switch to manual-SSID entry the first time the scan returns
        // empty (5 GHz-only router, hidden SSID, scan failure). One-shot so
        // a successful follow-up scan doesn't flip the user back to the list.
        if (found.isEmpty && !_manualSsidMode && !_autoSwitchedToManual) {
          _manualSsidMode = true;
          _autoSwitchedToManual = true;
        }
      });
    } finally {
      if (mounted) setState(() => _scanningHomeNetworks = false);
    }
  }

  String _homeSsid() {
    if (_manualSsidMode) return _manualSsidCtl.text.trim();
    return _selectedHomeNetwork?.ssid ?? '';
  }

  bool _canProvision() {
    if (_homeSsid().isEmpty) return false;
    final secured = _manualSsidMode
        ? _keyType != 0
        : (_selectedHomeNetwork?.secured ?? true);
    if (secured && _passwordCtl.text.isEmpty) return false;
    return true;
  }

  Future<void> _provision() async {
    final ssid = _homeSsid();
    final keyType = _manualSsidMode
        ? _keyType
        : ((_selectedHomeNetwork?.secured ?? true) ? 3 : 0);
    try {
      setState(() => _step = SetupStep.sendingCredentials);
      await _sendSetStaInfoWithRetry(ssid: ssid, keyType: keyType);

      setState(() => _step = SetupStep.waitingForJoin);
      await _binder.leave();
      // Give the device ~12s to drop its AP, reboot Wi-Fi, and join the home
      // AP — and the phone time to reattach to its preferred Wi-Fi.
      await Future<void>.delayed(const Duration(seconds: 12));

      setState(() => _step = SetupStep.discoveringOnHomeWifi);
      final device = await _findOnHomeWifi();

      if (!mounted || _step != SetupStep.discoveringOnHomeWifi) return;

      if (device == null) {
        _showError(
          'The HS300 did not announce itself on your Wi-Fi. Most likely causes:\n'
          '  • Wrong home Wi-Fi password.\n'
          '  • Your home network is 5 GHz only — HS300 cannot join 5 GHz.\n'
          '  • Your router blocks UDP broadcasts on the home subnet.\n'
          'Factory-reset the HS300 (hold a reset button until the LED blinks '
          'rapidly) and tap Start over.',
        );
        return;
      }

      setState(() {
        _discovered = device;
        _step = SetupStep.done;
      });
    } on WifiBinderException catch (e) {
      _showError(_describeError(e));
      await _binder.leave();
    } on Exception catch (e) {
      _showError(e.toString());
      await _binder.leave();
    }
  }

  Future<void> _sendSetStaInfoWithRetry({
    required String ssid,
    required int keyType,
  }) async {
    final cmd = KasaCommand.setStaInfo(
      ssid: ssid,
      password: _passwordCtl.text,
      keyType: keyType,
    );
    Object? lastErr;
    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        // Re-acquire the AP link before each attempt. Android frequently drops
        // the WifiNetworkSpecifier connection while the user is on the
        // credentials screen (no traffic for ~30 s).
        await _binder.ensureJoinedAp();
        final device = await _discoverDeviceInApMode();

        // Try TCP/9999 first — that is what python-kasa and the Kasa app
        // use. Some HS300 v2.0 units (observed on a TW unit, firmware
        // 1.0.x) accept the TCP handshake then immediately RST on accept,
        // probably from a leftover half-open socket inside the device's
        // tiny TCP stack.
        try {
          await Kasa.send(device: device, command: cmd);
          return;
        } on SocketException catch (e) {
          // errno 104 = ECONNRESET, 111 = ECONNREFUSED. Both mean TCP is
          // unusable right now; UDP/9999 with the same XOR JSON envelope
          // accepts the same `set_stainfo` and is what kicks in here.
          //
          // Only legacy-XOR devices speak UDP/9999. KLAP-firmware (1.1.x)
          // devices have UDP/9999 closed entirely — if a KLAP send raised
          // SocketException(104/111) the failure is a real one and the UDP
          // path would just stall on a timeout, so propagate instead.
          final retryable = e.osError?.errorCode == 104 ||
              e.osError?.errorCode == 111;
          if (retryable && !device.klap) {
            await KasaTransport.udpUnicastSend(
              host: device.address,
              command: cmd,
            );
            // Silence == probable success: once the device parses
            // set_stainfo it tears down its AP and switches radios to join
            // home Wi-Fi, so any reply on UDP/9999 from the AP IP would
            // race against that teardown. The next phase
            // (_findOnHomeWifi) is the real check.
            return;
          }
          rethrow;
        }
      } on WifiBinderException {
        rethrow;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    throw Exception('Could not deliver credentials to device: $lastErr');
  }


  Future<DiscoveredKasaDevice> _discoverDeviceInApMode() async {
    await for (final dev
        in KasaDiscovery.scan(timeout: const Duration(seconds: 4))) {
      if (dev.isHs300) return dev;
    }
    // AP gateway fallback (legacy XOR). Will fail loudly on 1.1.x.
    return DiscoveredKasaDevice(
      address: InternetAddress('192.168.0.1'),
      model: 'HS300',
      alias: '',
      hwVersion: '',
      swVersion: '',
    );
  }

  /// Look for the HS300 on the home Wi-Fi. Runs several short scan rounds
  /// (instead of one long blocking scan) so the AP-reappearance watchdog
  /// has time to fire between rounds — its 30 s cadence is forced on us by
  /// Android's foreground startScan throttle, so a 12 s one-shot would
  /// always finish before the watchdog could weigh in. Total window
  /// ~75 s, which spans HS300's typical 30-90 s reattempt-then-fall-back-
  /// to-AP window on a wrong password.
  Future<DiscoveredKasaDevice?> _findOnHomeWifi() async {
    for (var round = 0; round < 5; round++) {
      if (!mounted || _step != SetupStep.discoveringOnHomeWifi) return null;
      final found = await _singleHomeScan(
        timeout: const Duration(seconds: 15),
      );
      if (found != null) return found;
    }
    return null;
  }

  Future<DiscoveredKasaDevice?> _singleHomeScan({
    required Duration timeout,
  }) async {
    final completer = Completer<DiscoveredKasaDevice?>();
    StreamSubscription<DiscoveredKasaDevice>? sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    sub = KasaDiscovery.scan(timeout: timeout).listen(
      (device) {
        if (device.isHs300 && !completer.isCompleted) {
          timer.cancel();
          completer.complete(device);
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    final result = await completer.future;
    await sub?.cancel();
    return result;
  }

  /// Translate a [WifiBinderException] into actionable user-facing text.
  /// Mirrors broadlink-re's `_describeError`.
  String _describeError(WifiBinderException e) {
    switch (e.code) {
      case WifiBinderErrorCode.apUnavailable:
        return 'Could not see or join the device hotspot. '
            'Confirm the HS300 is factory-reset (LED blinking rapidly) and '
            'the phone is within ~2 m. Tap "Re-scan" to retry.';
      case WifiBinderErrorCode.apTimeout:
        return 'Timed out waiting for the device hotspot. Tap the SSID to '
            'retry — and tap "Connect" promptly when Android prompts.';
      case WifiBinderErrorCode.noWifi:
        return 'Your phone is not on any Wi-Fi network. Turn Wi-Fi on first.';
      case WifiBinderErrorCode.notKasa:
        return 'Phone is currently on "${e.message}", which is not a Kasa '
            'device hotspot. Switch in Wi-Fi settings or use "Re-scan".';
      case WifiBinderErrorCode.noNetwork:
        return 'Wi-Fi is on but Android cannot enumerate the active network. '
            'Toggle Wi-Fi off and on, then retry.';
      case WifiBinderErrorCode.noSsid:
        return 'Lost the connection to the device hotspot before credentials '
            'were sent. Tap "Start over" and try again — keep the phone close '
            'to the strip so Android does not roam back to home Wi-Fi.';
      case WifiBinderErrorCode.unsupported:
        return 'This Android version is too old. Android 10 (API 29) or '
            'higher is required (WifiNetworkSpecifier).';
      case WifiBinderErrorCode.argMissing:
        return 'Internal error: missing argument to platform call. ($e)';
      case WifiBinderErrorCode.unimplemented:
        return e.message;
      case WifiBinderErrorCode.unknown:
        return '${e.code.wireCode}: ${e.message}';
    }
  }

  void _showError(String msg) {
    _apPoller?.cancel();
    _apPoller = null;
    setState(() {
      _step = SetupStep.error;
      _error = msg;
    });
  }

  void _restart() {
    _apPoller?.cancel();
    _apPoller = null;
    setState(() {
      _step = SetupStep.intro;
      _error = null;
      _kasaApSsid = null;
      _currentBoundSsid = null;
      _selectedHomeNetwork = null;
      _manualSsidMode = false;
      _autoSwitchedToManual = false;
      _manualSsidCtl.clear();
      _passwordCtl.clear();
      _keyType = 3;
      _showPassword = false;
      _discovered = null;
    });
  }

  // ---- views ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Intercept the system Back gesture so the user rewinds through the
    // flow instead of crashing out of the app on first press. Back at intro
    // still exits; back anywhere else returns to intro via _restart() (which
    // cancels timers, releases the WifiBinder, and clears credentials).
    return PopScope(
      canPop: _step == SetupStep.intro,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step != SetupStep.intro) _restart();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Kasa HS300 Setup'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_step) {
            SetupStep.intro => _intro(),
            SetupStep.awaitDevice => _awaitDevice(),
            SetupStep.pickHomeWifi => _pickHomeWifi(),
            SetupStep.sendingCredentials => _busy('Sending Wi-Fi credentials to the strip…'),
            SetupStep.waitingForJoin => _busy('Waiting for the strip to join your Wi-Fi…'),
            SetupStep.discoveringOnHomeWifi =>
              _busy('Looking for the strip on your home Wi-Fi…'),
            SetupStep.done => _done(),
            SetupStep.error => _errorView(),
          },
        ),
      ),
      ),
    );
  }

  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        Text(
          'Set up a Kasa HS300 power strip without a TP-Link account.',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 16),
        Text('How it works:', style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text('1. Factory-reset the strip — long-press ANY outlet control button (top of the strip) until the LED blinks rapidly (orange/green).'),
        SizedBox(height: 8),
        Text('2. The app finds the device hotspot ("TP-LINK_Power Strip_XXXX") and joins it for you. Android will pop up a one-tap confirmation.'),
        SizedBox(height: 8),
        Text('3. Pick your home 2.4 GHz Wi-Fi from a list — or enter it manually if it\'s hidden.'),
        SizedBox(height: 8),
        Text('4. The strip joins your home network in ~15 seconds.'),
        Spacer(),
      ],
    ).addStretchedBottomButton(
      FilledButton(onPressed: _start, child: const Text('Next')),
    );
  }

  Widget _awaitDevice() {
    // Wrapped in SingleChildScrollView so the layout never overflows on short
    // viewports (e.g. landscape, large system font, soft keyboard up). The
    // previous version used a Spacer() to push the grey "Phone is currently
    // on ..." footer to the bottom, which produced a ~2.3 px bottom overflow
    // when the combined intrinsic height of children just barely exceeded the
    // available height.
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Connect to the device hotspot',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (_joiningKasaAp != null)
          _awaitStatus(
            spinning: true,
            text: 'Joining "$_joiningKasaAp"…\n'
                'Tap "Connect" if Android asks for confirmation.',
          )
        else if (_scanningKasaAps && _kasaApsFound.isEmpty)
          _awaitStatus(
            spinning: true,
            text: 'Scanning for nearby Kasa hotspots…\n'
                'Make sure the strip is factory-reset and the LED is '
                'blinking rapidly.',
          )
        else if (_kasaApsFound.isEmpty)
          _awaitStatus(
            spinning: false,
            text: 'No Kasa hotspots found nearby.\n'
                'Factory-reset the strip (hold its Wi-Fi/reset button until '
                'the LED blinks rapidly) and stay within 2 m.',
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick a hotspot to join:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._kasaApsFound.map((s) => Card(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      leading: const Icon(Icons.wifi_tethering),
                      title: Text(s),
                      onTap: () => _joinKasaAp(s),
                    ),
                  )),
            ],
          ),
        if (_joinError != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Auto-join failed: $_joinError\n'
                'Tap a hotspot to retry, or use Wi-Fi Settings below.',
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Re-scan'),
                onPressed: _scanningKasaAps ? null : _scanKasaAps,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('Wi-Fi Settings'),
                onPressed: _binder.openWifiSettings,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_currentBoundSsid != null && !_looksLikeKasaAp(_currentBoundSsid!))
          Text(
            'Phone is currently on "$_currentBoundSsid".',
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 12,
            ),
          ),
      ],
      ),
    );
  }

  Widget _awaitStatus({required bool spinning, required String text}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (spinning)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.info_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  Widget _pickHomeWifi() {
    final ap = _kasaApSsid ?? 'the strip';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pick the Wi-Fi for "$ap" to join',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Only 2.4 GHz networks are listed — the HS300 cannot use 5 GHz.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _manualSsidMode ? _manualSsidForm() : _homeNetworkList(),
        ),
        if (_manualSsidMode) ...[
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _canProvision() ? _provision : null,
            child: const Text('Provision'),
          ),
        ],
      ],
    );
  }

  Widget _homeNetworkList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Nearby networks', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_scanningHomeNetworks)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Re-scan',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: _refreshHomeNetworks,
              ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [
              if (!_scanningHomeNetworks) ..._homeNetworks.map(_homeNetworkTile),
              if (_homeNetworks.isEmpty && !_scanningHomeNetworks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No 2.4 GHz networks found nearby.\nTry "Enter SSID manually" below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit),
                label: const Text('Enter SSID manually (hidden network)'),
                onPressed: () {
                  setState(() {
                    _manualSsidMode = true;
                    _selectedHomeNetwork = null;
                    _passwordCtl.clear();
                  });
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _homeNetworkTile(WifiNetwork n) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: Icon(n.secured ? Icons.lock : Icons.lock_open),
        title: Text(n.ssid),
        trailing: Text(_signalBars(n.signalDbm),
            style: const TextStyle(fontFamily: 'monospace')),
        onTap: () => _promptAndProvisionForNetwork(n),
      ),
    );
  }

  /// Picker flow: ask for the password (or confirm an open network) in a
  /// modal dialog, then kick off provisioning. Keeps the picker screen
  /// uncluttered — the persistent credentials form is reserved for the
  /// manual-SSID (hidden network) branch where the user still needs to
  /// type the SSID and toggle WPA before the password.
  Future<void> _promptAndProvisionForNetwork(WifiNetwork n) async {
    if (!n.secured) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Use "${n.ssid}"?'),
          content: const Text(
            'This is an open Wi-Fi network — no password will be sent.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Provision'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
      setState(() {
        _selectedHomeNetwork = n;
        _passwordCtl.clear();
        _showPassword = false;
      });
      await _provision();
      return;
    }

    final ctl = TextEditingController();
    var show = false;
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Password for "${n.ssid}"'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            obscureText: !show,
            decoration: InputDecoration(
              labelText: 'Wi-Fi Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setLocal(() => show = !show),
              ),
            ),
            onSubmitted: (v) =>
                v.isEmpty ? null : Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => ctl.text.isEmpty
                  ? null
                  : Navigator.pop(ctx, ctl.text),
              child: const Text('Provision'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _selectedHomeNetwork = n;
      _passwordCtl.text = password;
      _showPassword = false;
    });
    await _provision();
  }

  Widget _manualSsidForm() {
    return ListView(
      children: [
        if (_autoSwitchedToManual)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No 2.4 GHz Wi-Fi networks were visible. HS300 cannot '
                      'join 5 GHz Wi-Fi. Either your home router has 2.4 GHz '
                      'disabled, or your home Wi-Fi is hidden — enter the '
                      'SSID below.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Back to network list'),
              onPressed: () {
                setState(() {
                  _manualSsidMode = false;
                  _manualSsidCtl.clear();
                  _passwordCtl.clear();
                });
              },
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _manualSsidCtl,
          decoration: const InputDecoration(
            labelText: 'Wi-Fi SSID (2.4 GHz)',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: _keyType,
          decoration: const InputDecoration(
            labelText: 'Security',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 3, child: Text('WPA2 (most common)')),
            DropdownMenuItem(value: 2, child: Text('WPA')),
            DropdownMenuItem(value: 1, child: Text('WEP (legacy)')),
            DropdownMenuItem(value: 0, child: Text('Open / no password')),
          ],
          onChanged: (v) => setState(() => _keyType = v ?? 3),
        ),
        if (_keyType != 0) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtl,
            decoration: InputDecoration(
              labelText: 'Wi-Fi Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ),
            obscureText: !_showPassword,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  static String _signalBars(int dbm) {
    if (dbm >= -55) return '████';
    if (dbm >= -65) return '███░';
    if (dbm >= -75) return '██░░';
    return '█░░░';
  }

  Widget _busy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _done() {
    final d = _discovered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Icon(Icons.check_circle, size: 64, color: Colors.green),
                ),
                const SizedBox(height: 16),
                const Center(
                  child: Text('Provisioning succeeded.',
                      style: TextStyle(fontSize: 20)),
                ),
                const SizedBox(height: 16),
                if (d != null) ...[
                  _row('Model', d.model),
                  _row('Alias', d.alias),
                  _row('IP', d.address.address),
                  _row('HW', d.hwVersion),
                  _row('FW', d.swVersion),
                  if (d.mac != null) _row('MAC', d.mac!),
                  if (d.klap)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'Note: this device speaks KLAP v${d.klapVersion ?? "?"} '
                        '(1.1.x firmware). Provisioning succeeded — the device '
                        'is on your Wi-Fi — but tools like python-kasa need to '
                        'authenticate with KLAP for on/off and energy queries. '
                        'The device reports '
                        '${d.isUnbound ? "an empty owner (good — hardcoded fallback creds will work)" : "a bound owner (will need that account's creds for HA)"}.',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: _restart, child: const Text('Set up another')),
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 60, child: Text(k, style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(v)),
        ]),
      );

  Widget _errorView() {
    final platformHint =
        Platform.isAndroid ? '' : '\n\nThis app currently only supports Android.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Icon(Icons.error_outline, size: 64, color: Colors.red),
                ),
                const SizedBox(height: 16),
                Text(_error ?? 'Unknown error.$platformHint',
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _restart, child: const Text('Start over')),
      ],
    );
  }
}

extension on Column {
  Widget addStretchedBottomButton(Widget button) {
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [...children, button],
    );
  }
}
