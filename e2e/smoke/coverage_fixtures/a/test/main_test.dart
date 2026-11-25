import 'package:flutter_test/flutter_test.dart';
import 'package:coverage_a/main.dart';

void main() {
  test('covers only the first function', () {
    expect(coveredA(), 1);
  });
}
