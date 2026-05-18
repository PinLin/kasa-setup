import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/main.dart';

void main() {
  testWidgets('App boots into intro screen', (tester) async {
    await tester.pumpWidget(const KasaSetupApp());

    expect(find.text('Kasa HS300 Setup'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('Tapping Start advances to credentials form', (tester) async {
    await tester.pumpWidget(const KasaSetupApp());
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text('Home Wi-Fi SSID (2.4 GHz)'), findsOneWidget);
    expect(find.text('Wi-Fi password'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });
}
