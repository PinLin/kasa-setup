// Deprecated. The Wi-Fi binder used to live here; it now lives under
// `lib/platform/` with proper iOS abstraction. See
// `lib/platform/wifi_binder.dart`, `wifi_binder_factory.dart`, and
// `platform_exception_codes.dart`. Re-exporting only so that any stragglers
// still resolve; new code should import from `package:kasa_setup/platform/...`
// directly.
export '../platform/platform_exception_codes.dart';
export '../platform/wifi_binder.dart';
export '../platform/wifi_binder_factory.dart';
