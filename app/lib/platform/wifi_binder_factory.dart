import 'dart:io' show Platform;

import 'wifi_binder.dart';
import 'wifi_binder_android.dart';
import 'wifi_binder_ios.dart';

/// Returns the right [WifiBinder] for the current platform.
///
/// Kept as a top-level function so tests can inject a mock binder via
/// `SetupHomeScreen.preview(binderOverride: …)` if needed.
WifiBinder createWifiBinder() {
  if (Platform.isAndroid) return WifiBinderAndroid();
  if (Platform.isIOS) return WifiBinderIos();
  throw UnsupportedError(
    'Unsupported platform: ${Platform.operatingSystem}. '
    'kasa_setup supports Android 10+.',
  );
}
