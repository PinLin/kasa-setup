import 'platform_exception_codes.dart';
import 'wifi_binder.dart';

/// iOS support is not implemented. `WifiNetworkSpecifier`'s iOS counterpart
/// `NEHotspotConfiguration` requires a paid Apple Developer Program account
/// and an entitlement, and the OS does not allow `bindProcessToNetwork` —
/// sockets always go through the default route. Out of scope for this app.
class WifiBinderIos implements WifiBinder {
  static const _msg = 'iOS provisioning is not implemented. Use Android 10+.';

  Never _unimplemented() =>
      throw WifiBinderException(WifiBinderErrorCode.unimplemented, _msg);

  @override
  Future<void> joinOpenAp(
    String ssid, {
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      _unimplemented();

  @override
  Future<void> leave() async {
    // safe no-op so callers can put it in finally{}
  }

  @override
  Future<String?> currentBoundSsid() async => null;

  @override
  Future<List<String>> scanKasaSsids() async => const [];

  @override
  Future<List<WifiNetwork>> scan24GhzNetworks() async => const [];

  @override
  Future<String> bindToCurrentApIfKasa() async => _unimplemented();

  @override
  Future<String> ensureJoinedAp({
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      _unimplemented();

  @override
  Future<void> openWifiSettings() async => _unimplemented();
}
