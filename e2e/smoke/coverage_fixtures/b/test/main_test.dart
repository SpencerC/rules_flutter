import 'package:flutter_test/flutter_test.dart';
import 'package:coverage_b/main.dart';

void main() {
  test('covers only the first function', () {
    expect(coveredB(), 2);
    expect(branchLabel(0), 0);
    expect(branchLabel(1), 1);
  });
}
