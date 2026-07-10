import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/main.dart';
import 'package:kasa_setup/platform/wifi_binder.dart';

/// Minimal fake so a widget test can drive the full password-dialog →
/// provision path without touching a real platform channel. Every method
/// returns immediately with a benign value, EXCEPT [ensureJoinedAp], which
/// blocks forever: that pins the provision coroutine at its first `await`
/// (inside `_sendSetStaInfoWithRetry`) so the test never reaches the real
/// Kasa network code (`KasaDiscovery.scan` / `Kasa.send`). The subtree swap
/// we are trying to exercise (`setState(_step = sendingCredentials)`) runs
/// synchronously *before* that await, so it still happens.
class FakeWifiBinder implements WifiBinder {
  final _never = Completer<String>();

  @override
  Future<void> joinOpenAp(String ssid,
          {Duration timeout = const Duration(seconds: 30)}) async {}

  @override
  Future<void> leave() async {}

  @override
  Future<String?> currentBoundSsid() async => null;

  @override
  Future<List<String>> scanKasaSsids() async => const [];

  @override
  Future<List<WifiNetwork>> scan24GhzNetworks() async => const [];

  @override
  Future<String> bindToCurrentApIfKasa() async => 'FakeKasa_AP';

  @override
  Future<String> ensureJoinedAp(
          {Duration timeout = const Duration(seconds: 30)}) =>
      _never.future; // never completes → provision stalls before network I/O

  @override
  Future<void> openWifiSettings() async {}
}

void main() {
  testWidgets(
      'password dialog → Provision does not crash with '
      "InheritedElement _dependents.isEmpty assertion", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SetupHomeScreen.preview(
        debugInitialStep: SetupStep.pickHomeWifi,
        debugHomeNetworks: const [
          WifiNetwork(ssid: 'HomeNet', signalDbm: -50, secured: true),
        ],
        binderOverride: FakeWifiBinder(),
      ),
    ));
    await tester.pumpAndSettle();

    // Open the password dialog for the secured network (autofocus TextField).
    await tester.tap(find.text('HomeNet'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi Password'), findsOneWidget);

    // Type a password and submit via the Provision button. This pops the
    // dialog and then synchronously setState()s the body from pickHomeWifi
    // to the sendingCredentials busy view — the tree swap under suspicion.
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.widgetWithText(FilledButton, 'Provision'));

    // Pump frames to let the dialog route tear down and the body rebuild.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // The body must have swapped from the picker to the sendingCredentials
    // busy view — proving we actually crossed the dialog-pop → setState →
    // _provision boundary that used to crash (the provision coroutine is now
    // parked on FakeWifiBinder.ensureJoinedAp, which never completes).
    expect(find.text('Sending Wi-Fi credentials to the strip…'), findsOneWidget);

    // Any framework assertion during those pumps is captured here. Before the
    // fix this held the InheritedElement `_dependents.isEmpty` assertion.
    expect(tester.takeException(), isNull);
  });
}
