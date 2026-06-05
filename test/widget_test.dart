import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pikppo/main.dart';

void main() {
  testWidgets('App boots without exceptions', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ButlerApp()));
    // Pump a few frames to let providers initialize. Avoid pumpAndSettle —
    // background timers (reminder + memory summary) keep the scheduler busy.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
