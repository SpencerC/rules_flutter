@Tags(['golden'])
library golden_test;

import 'package:flutter_test/flutter_test.dart';

import 'package:hello_world/main.dart';

void main() {
  testWidgets('MyApp renders its golden', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await expectLater(
      find.byType(MyApp),
      matchesGoldenFile('goldens/my_app.png'),
    );
  });
}
