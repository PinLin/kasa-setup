// Golden-file visual tests for every SetupStep render path.
//
// Generates one PNG per state under test/goldens/. Run:
//
//   flutter test --update-goldens test/visual_test.dart
//
// to regenerate; run without --update-goldens to compare future changes
// against the checked-in goldens.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/discovery.dart';
import 'package:kasa_setup/main.dart';

Future<void> _pumpAt(
  WidgetTester tester,
  Widget widget, {
  bool settle = true,
}) async {
  // Pin to a Pixel 6 logical size (411x914) so goldens are stable across
  // hosts and a typical mid-range phone fits the layout naturally.
  await tester.binding.setSurfaceSize(const Size(411, 914));
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
    home: widget,
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // For pages with always-running animations (e.g. CircularProgressIndicator)
    // pumpAndSettle would deadlock — pump once instead.
    await tester.pump();
  }
}

DiscoveredKasaDevice _legacyDevice() => DiscoveredKasaDevice(
      address: InternetAddress('192.168.87.121'),
      model: 'HS300(US)',
      alias: 'Living Room',
      hwVersion: '2.0',
      swVersion: '1.0.12 Build 220121 Rel.175814',
      mac: '78:8C:B5:AF:0A:00',
      deviceId: '800624BCAC7BD8CE5611627661B9B000212D2652',
    );

DiscoveredKasaDevice _klapDevice() => DiscoveredKasaDevice(
      address: InternetAddress('192.168.87.121'),
      model: 'HS300(US)',
      alias: '',
      hwVersion: '',
      swVersion: '',
      mac: '78:8C:B5:AF:0A:00',
      deviceId: '800624BCAC7BD8CE5611627661B9B000212D2652',
      klap: true,
      klapVersion: 2,
      owner: '',
      factoryDefault: true,
    );

void main() {
  testWidgets('01 intro', (tester) async {
    await _pumpAt(tester, const SetupHomeScreen.preview(debugInitialStep: SetupStep.intro));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/01_intro.png'));
  });

  testWidgets('02 enterCredentials', (tester) async {
    await _pumpAt(tester, const SetupHomeScreen.preview(debugInitialStep: SetupStep.enterCredentials));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/02_credentials.png'));
  });

  testWidgets('03 needPermission', (tester) async {
    await _pumpAt(tester, const SetupHomeScreen.preview(debugInitialStep: SetupStep.needPermission));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/03_need_permission.png'));
  });

  testWidgets('04 scanForDevice empty', (tester) async {
    await _pumpAt(tester, const SetupHomeScreen.preview(debugInitialStep: SetupStep.scanForDevice));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/04_scan_empty.png'));
  });

  testWidgets('05 scanForDevice with one device', (tester) async {
    await _pumpAt(
      tester,
      const SetupHomeScreen.preview(
        debugInitialStep: SetupStep.scanForDevice,
        debugKasaSsids: ['TP-LINK_Power Strip_0A00'],
      ),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/05_scan_one.png'));
  });

  testWidgets('06 scanForDevice with multiple devices', (tester) async {
    await _pumpAt(
      tester,
      const SetupHomeScreen.preview(
        debugInitialStep: SetupStep.scanForDevice,
        debugKasaSsids: [
          'TP-LINK_Power Strip_0A00',
          'TP-LINK_Smart Plug_F427',
          'Kasa_Smart Plug_3D9B',
        ],
      ),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/06_scan_many.png'));
  });

  testWidgets('07 busy state (sendingCredentials)', (tester) async {
    await _pumpAt(
      tester,
      const SetupHomeScreen.preview(debugInitialStep: SetupStep.sendingCredentials),
      settle: false,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/07_sending.png'));
  });

  testWidgets('08 done — legacy firmware (no KLAP warning)', (tester) async {
    await _pumpAt(
      tester,
      SetupHomeScreen.preview(
        debugInitialStep: SetupStep.done,
        debugDiscovered: _legacyDevice(),
      ),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/08_done_legacy.png'));
  });

  testWidgets('09 done — KLAP firmware (with warning)', (tester) async {
    await _pumpAt(
      tester,
      SetupHomeScreen.preview(
        debugInitialStep: SetupStep.done,
        debugDiscovered: _klapDevice(),
      ),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/09_done_klap.png'));
  });

  testWidgets('10 error', (tester) async {
    await _pumpAt(
      tester,
      const SetupHomeScreen.preview(
        debugInitialStep: SetupStep.error,
        debugError: 'Could not deliver credentials to device: SocketException: Connection timed out (192.168.0.1:9999)',
      ),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/10_error.png'));
  });
}
