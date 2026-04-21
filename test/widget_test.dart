import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pikppo/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ButlerApp()));
    await tester.pumpAndSettle();
    expect(find.text('Butler'), findsOneWidget);
  });
}
