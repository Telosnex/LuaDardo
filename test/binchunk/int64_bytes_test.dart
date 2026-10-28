import 'dart:typed_data';

import 'package:lua_dardo_plus/src/binchunk/int64_bytes.dart';
import 'package:test/test.dart';

void main() {
  // Within +-(2^53 - 1): exact on every platform, dart2js included.
  const values = [
    0,
    1,
    -1,
    255,
    -256,
    4294967295,
    4294967296,
    -4294967297,
    9007199254740991,
    -9007199254740991
  ];

  for (final endian in [Endian.little, Endian.big]) {
    test('signed round trip, $endian', () {
      final data = ByteData(8);
      for (final value in values) {
        setInt64(data, 0, value, endian);
        expect(getInt64(data, 0, endian), value);
      }
    });

    test('unsigned round trip, $endian', () {
      final data = ByteData(8);
      for (final value in values.where((v) => v >= 0)) {
        setUint64(data, 0, value, endian);
        expect(getUint64(data, 0, endian), value);
      }
    });
  }

  test('byte layout matches ByteData.setInt64 (two\'s complement)', () {
    final data = ByteData(8);
    setInt64(data, 0, -2, Endian.little);
    expect(data.buffer.asUint8List(), [254, 255, 255, 255, 255, 255, 255, 255]);
    setInt64(data, 0, 4294967298, Endian.big);
    expect(data.buffer.asUint8List(), [0, 0, 0, 1, 0, 0, 0, 2]);
  });
}
