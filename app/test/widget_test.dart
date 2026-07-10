import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/main.dart';

void main() {
  testWidgets('App boots into intro screen', (tester) async {
    await tester.pumpWidget(const KasaSetupApp());

    expect(find.text('Kasa HS300 Setup'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('Tapping "Enter SSID manually" reveals the manual credentials form',
      (tester) async {
    // Bypasses the real _start() flow (which needs platform-channel
    // permissions/Wi-Fi scanning) by dropping straight into pickHomeWifi
    // via the @visibleForTesting preview constructor.
    await tester.pumpWidget(const MaterialApp(
      home: SetupHomeScreen.preview(debugInitialStep: SetupStep.pickHomeWifi),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Enter SSID manually (hidden network)'), findsOneWidget);
    await tester.tap(find.text('Enter SSID manually (hidden network)'));
    await tester.pumpAndSettle();

    expect(find.text('Wi-Fi SSID (2.4 GHz)'), findsOneWidget);
    expect(find.text('Wi-Fi Password'), findsOneWidget);
    expect(find.text('Provision'), findsOneWidget);
  });
}
