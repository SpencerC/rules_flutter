import 'package:flutter_test/flutter_test.dart';
import 'package:hello_world/main.dart';

void main() {
  testWidgets('counter increments', (WidgetTester tester) async {
    await tester.pumpWidget(const HelloWorldApp());

    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    await tester.tap(find.byTooltip('Increment'));
    await tester.pump();

    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}
