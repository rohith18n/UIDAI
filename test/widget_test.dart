import 'package:flutter_test/flutter_test.dart';
import 'package:yellowsense_uidai/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const YellowSenseApp());
    expect(find.byType(YellowSenseApp), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });
}
