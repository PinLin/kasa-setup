# kasa-setup

A no-cloud Flutter Android app that **joins a factory-reset TP-Link Kasa
HS300 smart power strip to your home Wi-Fi without a TP-Link account**.

## What it does

After the strip is factory-reset and broadcasting its open AP, the app:

1. Asks for the Android permissions it needs to scan and join Wi-Fi.
2. Finds the device hotspot (`TP-LINK_*` / `Kasa_*`) and auto-joins it.
3. Lets you pick your home 2.4 GHz Wi-Fi from the scan results, or enter
   a hidden SSID manually.
4. Sends the credentials over the LAN to the device.
5. Confirms the device joined home Wi-Fi by re-discovering it there.

Everything runs on your phone over the LAN. No data goes to TP-Link
servers and no account is created.

## Tested device

- HS300 (US), firmware 1.0.12 — the version this app has been verified
  against end-to-end on real hardware.

## Build / run

Standard Flutter — see [`app/README.md`](app/README.md).

```
cd app
flutter pub get
flutter run --release        # connected Android device
flutter build apk --release  # produces app-release.apk
```

Requirements: Android 10+ (the app uses `WifiNetworkSpecifier`), Dart
3.4+, Flutter 3.22+.

## License

MIT — see [`LICENSE`](LICENSE). No TP-Link assets are redistributed.
