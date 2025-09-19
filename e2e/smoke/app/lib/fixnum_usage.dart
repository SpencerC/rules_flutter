/// Example Dart code that uses the fixnum package from pub.dev
import 'package:fixnum/fixnum.dart';

/// A simple class that demonstrates using fixnum Int32 and Int64 types
class FixnumExample {
  /// Create a 32-bit integer
  static Int32 createInt32(int value) {
    return Int32(value);
  }

  /// Create a 64-bit integer
  static Int64 createInt64(int value) {
    return Int64(value);
  }

  /// Perform arithmetic with Int32
  static Int32 addInt32(Int32 a, Int32 b) {
    return a + b;
  }

  /// Perform arithmetic with Int64
  static Int64 multiplyInt64(Int64 a, Int64 b) {
    return a * b;
  }

  /// Convert Int64 to string representation
  static String int64ToString(Int64 value) {
    return value.toString();
  }

  /// Demonstrate bit operations
  static Int32 bitwiseAnd(Int32 a, Int32 b) {
    return a & b;
  }

  /// Check if an Int64 is negative
  static bool isNegative(Int64 value) {
    return value.isNegative;
  }
}

/// Simple function to test basic fixnum functionality
void demonstrateFixnum() {
  // Test Int32
  final int32a = FixnumExample.createInt32(123456);
  final int32b = FixnumExample.createInt32(789012);
  final int32Sum = FixnumExample.addInt32(int32a, int32b);

  print('Int32: $int32a + $int32b = $int32Sum');

  // Test Int64
  final int64a = FixnumExample.createInt64(9223372036854775000);
  final int64b = FixnumExample.createInt64(2);
  final int64Product = FixnumExample.multiplyInt64(int64a, int64b);

  print('Int64: $int64a * $int64b = $int64Product');
  print('Is negative: ${FixnumExample.isNegative(int64Product)}');

  // Test bitwise operations
  final bitwiseResult = FixnumExample.bitwiseAnd(Int32(0xFF00), Int32(0x0F0F));
  print('Bitwise AND: 0xFF00 & 0x0F0F = ${bitwiseResult.toHexString()}');
}