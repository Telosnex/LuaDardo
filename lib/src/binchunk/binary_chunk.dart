import 'dart:convert';
import 'dart:typed_data';

import 'buffer.dart';

const luaSignature = [0x1b, 0x4c, 0x75, 0x61];
const luacVersion = 0x53;
const luacFormat = 0;
const luacData = [0x19, 0x93, 0x0d, 0x0a, 0x1a, 0x0a];
const cintSize = 4;
const csizetSize = 8;
const instructionSize = 4;
const luaIntegerSize = 8;
const luaNumberSize = 8;
const luacInt = 0x5678;
const luacNum = 370.5;

/// 常量类型
const tag_nil = 0x00;
const tag_boolean = 0x01;
const tag_number = 0x03;
const tag_integer = 0x13;
const tag_short_str = 0x04;
const tag_long_str = 0x14;

// Documents the header that BinaryChunk._checkHead reads; not instantiated.
// ignore: unused_element
class _Header {
  /// 签名。二进制文件的魔数:0x1B4C7561
  Uint8List signature = Uint8List(4);

  /// 版本号。值为大版本号乘以16加小版本号
  int? version;

  /// 格式号
  int? format;

  /// 前两个字节是0x1993，是Lua 1.0发布的年份；
  /// 后四个字节依次是回车符（0x0D）、换行符（0x0A）、
  /// 替换符（0x1A）和另一个换行符
  Uint8List luacData = Uint8List(6);

  /// 分别记录cint、size_t、Lua虚拟机指令、
  /// Lua整数和Lua浮点数5种数据类型在二进制的字节长度
  int? cintSize;
  int? sizetSize;
  int? instructionSize;
  int? luaIntegerSize;
  int? luaNumberSize;

  /// 存放Lua整数值0x5678
  int? luacInt;

  /// 存放Lua浮点数370.5
  double? luacNum;
}

class Prototype {
  /// 源文件名
  String? source;

  /// 起始行号
  int? lineDefined;

  /// 终止行号
  int? lastLineDefined;

  /// 函数固定参数个数
  int? numParams;

  /// 是否有变长参数
  int? isVararg;

  /// 寄存器数量
  late int maxStackSize;

  /// 指令表
  late Uint32List code;

  /// 常量表
  late List<Object?> constants;

  /// Upvalue表
  late List<Upvalue?> upvalues;

  /// 子函数原型表
  late List<Prototype?> protos;

  /// 行号表
  late Uint32List lineInfo;

  /// 局部变量表
  late List<LocVar?> locVars;

  /// Upvalue名字列表
  late List<String?> upvalueNames;

  Prototype();

  Prototype.from(ByteDataReader data, String parentSource) {
    source = BinaryChunk.getLuaString(data);
    if (source!.isEmpty) {
      source = parentSource;
    }

    lineDefined = data.readUint32();
    lastLineDefined = data.readUint32();
    numParams = data.readUint8();
    isVararg = data.readUint8();
    maxStackSize = data.readUint8();
    var len = data.readUint32();

    code = Uint32List(len);
    for (var i = 0; i < len; i++) {
      code[i] = data.readUint32();
    }

    len = data.readUint32();
    constants = List.filled(len, null);
    for (var i = 0; i < len; i++) {
      var kind = data.readUint8();
      switch (kind) {
        case tag_nil:
          constants[i] = null;
          break;
        case tag_boolean:
          constants[i] = data.readUint8() != 0;
          break;
        case tag_integer:
          constants[i] = data.readUint64();
          break;
        case tag_number:
          constants[i] = data.readFloat64();
          break;
        case tag_short_str:
        case tag_long_str:
          constants[i] = BinaryChunk.getLuaString(data);
          break;
        default:
          throw Exception("corrupted!");
      }
    }

    len = data.readUint32();
    upvalues = List.filled(len, null);
    for (var i = 0; i < len; i++) {
      upvalues[i] = Upvalue.from(data);
    }

    len = data.readUint32();
    protos = List.filled(len, null);
    for (var i = 0; i < len; i++) {
      protos[i] = Prototype.from(data, parentSource);
    }

    len = data.readUint32();
    lineInfo = Uint32List(len);
    for (var i = 0; i < len; i++) {
      lineInfo[i] = data.readUint32();
    }

    len = data.readUint32();
    locVars = List.filled(len, null);
    for (var i = 0; i < len; i++) {
      locVars[i] = LocVar.from(data);
    }

    len = data.readUint32();

    upvalueNames = List.filled(len, null);
    for (var i = 0; i < len; i++) {
      upvalueNames[i] = BinaryChunk.getLuaString(data);
    }
  }
}

class Upvalue {
  int? instack;
  int? idx;

  Upvalue();

  Upvalue.from(ByteDataReader blob) {
    instack = blob.readUint8();
    idx = blob.readUint8();
  }
}

class LocVar {
  String? varName;
  int? startPC;
  int? endPC;

  LocVar();
  LocVar.from(ByteDataReader blob) {
    varName = BinaryChunk.getLuaString(blob);
    startPC = blob.readUint32();
    endPC = blob.readUint32();
  }
}

class BinaryChunk {
  /// 解析二进制
  static Prototype unDump(Uint8List data) {
    var byteReader = ByteDataReader(endian: Endian.little)..add(data);
    _checkHead(byteReader);
    byteReader.readUint8(); // 跳过 size_upvalues
    return Prototype.from(byteReader, "");
  }

  static void _checkHead(ByteDataReader blob) {
    var magicNum = blob.read(4);

    for (var i = 0; i < 4; i++) {
      if (luaSignature[i] != magicNum[i]) {
        throw Exception("not a precompiled chunk!");
      }
    }

    if (luacVersion != blob.readUint8()) {
      throw Exception("version mismatch!");
    }

    if (luacFormat != blob.readUint8()) {
      throw Exception("format mismatch!");
    }

    var data = blob.read(6);
    for (var i = 0; i < 6; i++) {
      if (data[i] != luacData[i]) {
        throw Exception("LUAC_DATA corrupted!");
      }
    }

    if (cintSize != blob.readUint8()) {
      throw Exception("int size mismatch!");
    }

    if (csizetSize != blob.readUint8()) {
      throw Exception("size_t size mismatch!");
    }

    if (instructionSize != blob.readUint8()) {
      throw Exception("instruction size mismatch!");
    }

    if (luaIntegerSize != blob.readUint8()) {
      throw Exception("lua_Integer size mismatch!");
    }

    if (luaNumberSize != blob.readUint8()) {
      throw Exception("lua_Number size mismatch!");
    }

    if (luacInt != blob.readUint64()) {
      throw Exception("endianness mismatch!");
    }

    if (luacNum != blob.readFloat64()) {
      throw Exception("float format mismatch!");
    }
  }

  static String getLuaString(ByteDataReader blob) {
    int size = blob.readUint8();
    if (size == 0) {
      return "";
    }
    if (size == 0xFF) {
      size = blob.readUint64(); // size_t
    }

    var strBytes = blob.read(size - 1);
    return utf8.decode(strBytes);
  }

  static bool isBinaryChunk(Uint8List data) {
    if (data.length < 4) {
      return false;
    }
    for (int i = 0; i < 4; i++) {
      if (data[i] != luaSignature[i]) {
        return false;
      }
    }
    return true;
  }

  /// Serialize a Prototype to Lua 5.3 binary chunk format.
  static Uint8List dump(Prototype proto, {bool strip = false}) {
    var w = ByteDataWriter(endian: Endian.little);
    // Header
    w.write(Uint8List.fromList(luaSignature));
    w.writeUint8(luacVersion);
    w.writeUint8(luacFormat);
    w.write(Uint8List.fromList(luacData));
    w.writeUint8(cintSize);
    w.writeUint8(csizetSize);
    w.writeUint8(instructionSize);
    w.writeUint8(luaIntegerSize);
    w.writeUint8(luaNumberSize);
    w.writeInt64(luacInt, Endian.little);
    w.writeFloat64(luacNum, Endian.little);
    // size_upvalues
    w.writeUint8(proto.upvalues.length);
    // Prototype
    _dumpProto(w, proto, strip);
    return w.toBytes();
  }

  static void _dumpProto(ByteDataWriter w, Prototype proto, bool strip) {
    _putLuaString(w, strip ? '' : (proto.source ?? ''));
    w.writeUint32(proto.lineDefined ?? 0, Endian.little);
    w.writeUint32(proto.lastLineDefined ?? 0, Endian.little);
    w.writeUint8(proto.numParams ?? 0);
    w.writeUint8(proto.isVararg ?? 0);
    w.writeUint8(proto.maxStackSize);

    // Instructions
    w.writeUint32(proto.code.length, Endian.little);
    for (var i = 0; i < proto.code.length; i++) {
      w.writeUint32(proto.code[i], Endian.little);
    }

    // Constants
    w.writeUint32(proto.constants.length, Endian.little);
    for (var c in proto.constants) {
      if (c == null) {
        w.writeUint8(tag_nil);
      } else if (c is bool) {
        w.writeUint8(tag_boolean);
        w.writeUint8(c ? 1 : 0);
      } else if (c is int) {
        w.writeUint8(tag_integer);
        w.writeInt64(c, Endian.little);
      } else if (c is double) {
        w.writeUint8(tag_number);
        w.writeFloat64(c, Endian.little);
      } else if (c is String) {
        w.writeUint8(c.length < 253 ? tag_short_str : tag_long_str);
        _putLuaString(w, c);
      }
    }

    // Upvalues
    w.writeUint32(proto.upvalues.length, Endian.little);
    for (var uv in proto.upvalues) {
      w.writeUint8(uv?.instack ?? 0);
      w.writeUint8(uv?.idx ?? 0);
    }

    // Sub-prototypes
    w.writeUint32(proto.protos.length, Endian.little);
    for (var p in proto.protos) {
      _dumpProto(w, p!, strip);
    }

    // Line info
    if (strip) {
      w.writeUint32(0, Endian.little);
    } else {
      w.writeUint32(proto.lineInfo.length, Endian.little);
      for (var i = 0; i < proto.lineInfo.length; i++) {
        w.writeUint32(proto.lineInfo[i], Endian.little);
      }
    }

    // Local variables
    if (strip) {
      w.writeUint32(0, Endian.little);
    } else {
      w.writeUint32(proto.locVars.length, Endian.little);
      for (var lv in proto.locVars) {
        _putLuaString(w, lv?.varName ?? '');
        w.writeUint32(lv?.startPC ?? 0, Endian.little);
        w.writeUint32(lv?.endPC ?? 0, Endian.little);
      }
    }

    // Upvalue names
    if (strip) {
      w.writeUint32(0, Endian.little);
    } else {
      w.writeUint32(proto.upvalueNames.length, Endian.little);
      for (var name in proto.upvalueNames) {
        _putLuaString(w, name ?? '');
      }
    }
  }

  static void _putLuaString(ByteDataWriter w, String s) {
    if (s.isEmpty) {
      w.writeUint8(0);
      return;
    }
    var bytes = utf8.encode(s);
    var size = bytes.length + 1; // Lua adds 1 to the stored size
    if (size < 0xFF) {
      w.writeUint8(size);
    } else {
      w.writeUint8(0xFF);
      w.writeUint64(size, Endian.little);
    }
    w.write(Uint8List.fromList(bytes));
  }
}
