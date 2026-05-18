# kasa-setup app

The Flutter Android app itself. See the [top-level README](../README.md)
for project context.

## What it does

1. Asks for the Android permissions needed to scan and join Wi-Fi.
2. Scans for nearby APs whose SSID looks like a factory-reset Kasa
   device (`TP-LINK_Smart Plug_*`, `TP-LINK_Power Strip_*`,
   `Kasa_Smart Plug_*`) and auto-joins the device's open AP via
   `WifiNetworkSpecifier` + `bindProcessToNetwork`.
3. Lets you pick your home 2.4 GHz Wi-Fi (or enter a hidden SSID
   manually) and type the password in a dialog.
4. Sends the home Wi-Fi credentials to the device over the LAN.
5. Releases the AP and confirms the device joined home Wi-Fi by
   re-discovering it on the LAN.

## Tested

- HS300 (US) firmware 1.0.12 on a Samsung Android 13 phone.

## Build / run

```bash
flutter pub get
flutter run --release        # connected Android device
flutter build apk --release  # produces build/app/outputs/flutter-apk/app-release.apk
```

Requirements: Android 10+ (the app uses `WifiNetworkSpecifier`),
Dart 3.4+, Flutter 3.22+.

## Tests

```bash
flutter test
```

86+ pure-Dart unit tests covering the cipher / protocol / discovery
layers, plus golden-file widget tests for the UI state machine.

## Why Android-only

Android 10+ exposes `WifiNetworkSpecifier` +
`ConnectivityManager.requestNetwork`, which lets a regular app join a
temporary open AP and bind sockets to it. iOS restricts
`NEHotspotConfiguration` heavily (entitlements, prompts, no process
binding), and is out of scope here.

`minSdk = 29` (Android 10).

## Known limitations

- **No iOS support** — see above.
- **No persistent device registry** — this app only handles setup.
  Pair the strip with [python-kasa] or Home Assistant for actual
  control.
- **Some OEMs throttle `WifiManager.startScan()`** (Samsung One UI,
  MIUI). If the device-AP scan returns nothing, open the system Wi-Fi
  picker once to force a real scan, then come back.
- **Uses a debug signing config in release builds** so
  `flutter run --release` works without a keystore. Replace before
  shipping anywhere real.

[python-kasa]: https://python-kasa.readthedocs.io/

## Layout

```
app/
├── pubspec.yaml
├── lib/
│   ├── main.dart           # state machine + UI
│   ├── kasa/               # Dart-side protocol layer
│   └── platform/           # Dart side of the Wi-Fi platform channel
├── test/                   # unit + widget tests
└── android/
    └── app/src/main/
        ├── AndroidManifest.xml
        └── kotlin/me/pinlin/kasa_setup/
            ├── MainActivity.kt
            ├── KasaSetupPlugin.kt
            └── WifiBinder.kt
```
