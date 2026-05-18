import 'platform_exception_codes.dart';

/// Platform-abstract Wi-Fi binder. On Android, programmatically joins an open
/// Kasa device AP via `WifiNetworkSpecifier` and `bindProcessToNetwork`, so
/// Dart-side `Socket` / `RawDatagramSocket` traffic routes through the AP.
abstract class WifiBinder {
  /// Connect to an open AP named [ssid]. Throws [WifiBinderException] with
  /// [WifiBinderErrorCode.apUnavailable] or [WifiBinderErrorCode.apTimeout]
  /// on failure.
  Future<void> joinOpenAp(
    String ssid, {
    Duration timeout = const Duration(seconds: 30),
  });

  /// Release the bound network so the OS returns the phone to its preferred
  /// Wi-Fi. Idempotent — safe to call when no network is bound.
  Future<void> leave();

  /// SSID the phone reports as its current Wi-Fi, or null. Used to detect
  /// whether the user manually joined a Kasa AP from Settings.
  Future<String?> currentBoundSsid();

  /// Scan for AP SSIDs that look like a factory-reset Kasa device.
  /// (`TP-LINK_Smart Plug_*`, `TP-LINK_Power Strip_*`, `Kasa_Smart Plug_*`)
  Future<List<String>> scanKasaSsids();

  /// Scan 2.4 GHz APs (excluding Kasa device APs) sorted by signal strength.
  Future<List<WifiNetwork>> scan24GhzNetworks();

  /// If the phone is already manually connected to a Kasa AP, bind the
  /// process to that network and return the SSID. Throws otherwise.
  Future<String> bindToCurrentApIfKasa();

  /// Make sure the process is routed through the Kasa AP previously joined via
  /// [joinOpenAp]. Cheap if the link is still alive; otherwise transparently
  /// re-issues the join (Android usually skips the dialog for a recently
  /// approved SSID). Throws [WifiBinderException] if the link cannot be
  /// recovered. Returns the SSID re-bound to.
  Future<String> ensureJoinedAp({
    Duration timeout = const Duration(seconds: 30),
  });

  /// Open the platform's Wi-Fi settings page (escape hatch).
  Future<void> openWifiSettings();
}

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signalDbm,
    required this.secured,
  });

  final String ssid;
  final int signalDbm;
  final bool secured;

  factory WifiNetwork.fromMap(Map<String, dynamic> m) => WifiNetwork(
        ssid: (m['ssid'] as String?) ?? '',
        signalDbm: (m['signal'] as int?) ?? -100,
        secured: (m['secured'] as bool?) ?? true,
      );
}

class WifiBinderException implements Exception {
  WifiBinderException(this.code, this.message, [this.details]);
  final WifiBinderErrorCode code;
  final String message;
  final Object? details;

  @override
  String toString() => 'WifiBinderException(${code.name}): $message';
}
