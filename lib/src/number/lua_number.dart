import 'dart:math' as math;

class LuaNumber {
  static double _pow2(int exp) => math.pow(2.0, exp).toDouble();

  static bool isInteger(double f) {
    return f == f.toInt();
  }

  // TODO
  static int? parseInteger(String str) {
    try {
      return int.parse(str);
    } catch (e) {
      return null;
    }
  }

  // TODO
  static double? parseFloat(String str) {
    try {
      return double.parse(str);
    } catch (e) {
      // Dart's double.parse doesn't handle hex floats (0x1p-3).
      // Parse manually: 0x<mantissa>p<exponent> = mantissa * 2^exponent
      var s = str.toLowerCase();
      if (s.startsWith('0x') && s.contains('p')) {
        var pIdx = s.indexOf('p');
        var mantissaStr = s.substring(2, pIdx);
        var expStr = s.substring(pIdx + 1);
        // Parse hex mantissa (may have a dot)
        double mantissa;
        if (mantissaStr.contains('.')) {
          var parts = mantissaStr.split('.');
          var intPart = parts[0].isEmpty ? 0 : int.parse(parts[0], radix: 16);
          var fracStr = parts[1];
          var fracPart = fracStr.isEmpty
              ? 0.0
              : int.parse(fracStr, radix: 16) / (1 << (fracStr.length * 4));
          mantissa = intPart + fracPart;
        } else {
          mantissa = int.parse(mantissaStr, radix: 16).toDouble();
        }
        var exp = int.parse(expStr);
        // Use dart:math pow to avoid integer overflow on large exponents.
        return mantissa * _pow2(exp);
      }
      return null;
    }
  }
}
