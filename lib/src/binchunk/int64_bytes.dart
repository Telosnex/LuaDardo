import 'dart:typed_data';

/// True under dart2js, where every number is a JavaScript double.
const bool _jsNumbers = identical(1, 1.0);

const int _two32 = 4294967296;

/// ByteData's 64-bit accessors throw under dart2js ("Int64 accessor not
/// supported"). There these write and read two 32-bit halves instead, exact
/// for integers within +-(2^53 - 1), the integers dart2js has.
void setInt64(ByteData data, int offset, int value, Endian endian) {
  if (!_jsNumbers) {
    data.setInt64(offset, value, endian);
    return;
  }
  final high = (value / _two32).floor();
  final low = value - high * _two32;
  final little = endian == Endian.little;
  data.setUint32(offset + (little ? 0 : 4), low, endian);
  data.setInt32(offset + (little ? 4 : 0), high, endian);
}

void setUint64(ByteData data, int offset, int value, Endian endian) {
  if (!_jsNumbers) {
    data.setUint64(offset, value, endian);
    return;
  }
  setInt64(data, offset, value, endian);
}

int getInt64(ByteData data, int offset, Endian endian) {
  if (!_jsNumbers) return data.getInt64(offset, endian);
  final little = endian == Endian.little;
  final low = data.getUint32(offset + (little ? 0 : 4), endian);
  final high = data.getInt32(offset + (little ? 4 : 0), endian);
  return high * _two32 + low;
}

int getUint64(ByteData data, int offset, Endian endian) {
  if (!_jsNumbers) return data.getUint64(offset, endian);
  final little = endian == Endian.little;
  final low = data.getUint32(offset + (little ? 0 : 4), endian);
  final high = data.getUint32(offset + (little ? 4 : 0), endian);
  return high * _two32 + low;
}
