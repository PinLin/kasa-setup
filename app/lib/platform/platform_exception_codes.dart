/// Error codes shared between Dart and the platform plugin. The string values
/// must match the codes raised by Kotlin in `WifiBinder.kt` / `MainActivity.kt`.
enum WifiBinderErrorCode {
  /// AP discovery / join failed — couldn't see or attach to the device hotspot.
  apUnavailable('UNAVAILABLE'),

  /// Auto-join exceeded the timeout (user did not tap "Connect" in time).
  apTimeout('TIMEOUT'),

  /// Phone is not connected to any Wi-Fi network.
  noWifi('NO_WIFI'),

  /// Phone is on Wi-Fi but the SSID does not look like a Kasa device AP.
  notKasa('NOT_KASA'),

  /// Wi-Fi network not enumerable via ConnectivityManager.allNetworks.
  noNetwork('NO_NETWORK'),

  /// ensureJoinedAp called before any joinOpenAp in this session.
  noSsid('NO_SSID'),

  /// Android < 10 — we require WifiNetworkSpecifier.
  unsupported('UNSUPPORTED'),

  /// Required argument missing in the platform-channel call.
  argMissing('ARG'),

  /// Platform does not implement this method (iOS stub).
  unimplemented('UNIMPLEMENTED'),

  /// Anything we did not classify.
  unknown('UNKNOWN');

  const WifiBinderErrorCode(this.wireCode);
  final String wireCode;

  static WifiBinderErrorCode fromWire(String code) {
    for (final v in WifiBinderErrorCode.values) {
      if (v.wireCode == code) return v;
    }
    return WifiBinderErrorCode.unknown;
  }
}
