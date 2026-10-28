import 'dart:convert';
import 'dart:typed_data';

import 'package:sprintf/sprintf.dart';

import '../api/lua_state.dart';
import '../api/lua_type.dart';
import '../binchunk/binary_chunk.dart';
import '../state/closure.dart';
import '../state/lua_state_impl.dart';
import 'lua_pattern.dart';

class StringLib {
  static final tagPattern =
      RegExp(r'%[ #+-0]?[0-9]*(\.[0-9]+)?[cdeEfgGioqsuxX%]');

  /// Controls whether string.format uses optimised inline formatting.
  ///
  /// When `true` (default): caches parsed format strings and handles common
  /// specifiers (%d, %s, %f, etc.) without calling the [sprintf] package.
  /// When `false`: original behaviour (benchmark baseline).
  static bool useFastFormat = true;

  /// LRU-ish cache of parsed format strings.  Cleared when it exceeds 64
  /// entries to avoid unbounded growth.
  static final Map<String, List<String?>> _fmtCache = {};
  static const int _fmtCacheMaxSize = 64;

  static const Map<String, DartFunction> _strLib = {
    "len": _strLen,
    "rep": _strRep,
    "reverse": _strReverse,
    "lower": _strLower,
    "upper": _strUpper,
    "sub": _strSub,
    "byte": _strByte,
    "char": _strChar,
    "dump": _strDump,
    "format": _strFormat,
    "packsize": _strPackSize,
    "pack": _strPack,
    "unpack": _strUnpack,
    "find": _strFind,
    "match": _strMatch,
    "gsub": _strGsub,
    "gmatch": _strGmatch,
  };

  static int openStringLib(LuaState ls) {
    ls.newLib(_strLib);
    _createMetatable(ls);
    return 1;
  }

  static void _createMetatable(LuaState ls) {
    ls.createTable(0, 1); /* table to be metatable for strings */
    ls.pushString("dummy"); /* dummy string */
    ls.pushValue(-2); /* copy table */
    ls.setMetatable(-2); /* set table as metatable for strings */
    ls.pop(1); /* pop dummy string */
    ls.pushValue(-2); /* get string library */
    ls.setField(-2, "__index"); /* metatable.__index = string */
    ls.pop(1); /* pop metatable */
  }

  /* Basic String Functions */

// string.len (s)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.len
// lua-5.3.4/src/lstrlib.c#str_len()
  static int _strLen(LuaState ls) {
    String s = ls.checkString(1)!;
    ls.pushInteger(s.length);
    return 1;
  }

// string.rep (s, n [, sep])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.rep
// lua-5.3.4/src/lstrlib.c#str_rep()
  static int _strRep(LuaState ls) {
    String? s = ls.checkString(1);
    int n = ls.checkInteger(2)!;
    String? sep = ls.optString(3, "");

    if (n <= 0) {
      ls.pushString("");
    } else if (n == 1) {
      ls.pushString(s);
    } else {
      var a = [];
      for (var i = 0; i < n; i++) {
        a.add(s);
      }

      ls.pushString(a.join(sep!));
    }

    return 1;
  }

// string.reverse (s)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.reverse
// lua-5.3.4/src/lstrlib.c#str_reverse()
  static int _strReverse(LuaState ls) {
    String s = ls.checkString(1)!;
    ls.pushString(String.fromCharCodes(s.codeUnits.reversed));
    return 1;
  }

// string.lower (s)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.lower
// lua-5.3.4/src/lstrlib.c#str_lower()
  static int _strLower(LuaState ls) {
    String s = ls.checkString(1)!;
    ls.pushString(s.toLowerCase());
    return 1;
  }

// string.upper (s)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.upper
// lua-5.3.4/src/lstrlib.c#str_upper()
  static int _strUpper(LuaState ls) {
    String s = ls.checkString(1)!;
    ls.pushString(s.toUpperCase());
    return 1;
  }

// string.sub (s, i [, j])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.sub
// lua-5.3.4/src/lstrlib.c#str_sub()
  static int _strSub(LuaState ls) {
    String s = ls.checkString(1)!;
    var sLen = s.length;
    var i = posRelat(ls.checkInteger(2)!, sLen);
    var j = posRelat(ls.optInteger(3, -1)!, sLen);

    if (i < 1) {
      i = 1;
    }
    if (j > sLen) {
      j = sLen;
    }

    if (i <= j) {
      ls.pushString(s.substring(i - 1, j));
    } else {
      ls.pushString("");
    }

    return 1;
  }

// string.byte (s [, i [, j]])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.byte
// lua-5.3.4/src/lstrlib.c#str_byte()
  static int _strByte(LuaState ls) {
    String s = ls.checkString(1)!;
    var sLen = s.length;
    var i = posRelat(ls.optInteger(2, 1)!, sLen);
    var j = posRelat(ls.optInteger(3, i)!, sLen);

    if (i < 1) {
      i = 1;
    }
    if (j > sLen) {
      j = sLen;
    }

    if (i > j) {
      return 0; /* empty interval; return no values */
    }
//if (j - i >= INT_MAX) { /* arithmetic overflow? */
//  return ls.Error2("string slice too long")
//}

    var n = j - i + 1;
    ls.checkStack2(n, "string slice too long");

    for (var k = 0; k < n; k++) {
      ls.pushInteger(s.codeUnitAt(i + k - 1));
    }
    return n;
  }

// string.char (···)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.char
// lua-5.3.4/src/lstrlib.c#str_char()
  static int _strChar(LuaState ls) {
    var nArgs = ls.getTop();

    // s = make([]byte, nArgs)
    var s = List<int>.filled(nArgs,0);
    for (var i = 1; i <= nArgs; i++) {
      var c = ls.checkInteger(i)!;
      ls.argCheck((c & 0xff) == c, i, "value out of range");
      s[i - 1] = c;
    }

    ls.pushString(String.fromCharCodes(s));
    return 1;
  }

// string.dump (function [, strip])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.dump
// lua-5.3.4/src/lstrlib.c#str_dump()
  static int _strDump(LuaState ls) {
    // Arg 1 must be a Lua function.
    ls.checkType(1, LuaType.luaFunction);
    var strip = ls.toBoolean(2);

    // Access the closure from the internal stack.
    var impl = ls as LuaStateImpl;
    var val = impl.getRawValue(1);
    if (val is! Closure || val.proto == null) {
      throw Exception("unable to dump given function");
    }

    var bytes = BinaryChunk.dump(val.proto!, strip: strip);
    ls.pushString(String.fromCharCodes(bytes));
    return 1;
  }

/* PACK/UNPACK */

  /// Returns the byte size for a pack format option.
  /// [opt] is the format char, [n] is the optional size argument.
  static int _packOptSize(String opt, int n) {
    switch (opt) {
      case 'b': case 'B': return 1;
      case 'h': case 'H': return 2;
      case 'i': case 'I': return n;
      case 'l': case 'L': return 8;
      case 'j': case 'J': return 8;
      case 'f': return 4;
      case 'd': case 'n': return 8;
      default: return 0;
    }
  }

  /// Parse a pack format string into a list of (option, size) pairs.
  /// Also handles endianness markers. Returns list of maps with keys:
  /// 'opt' (String), 'size' (int), 'endian' (Endian).
  static List<Map<String, dynamic>> _parseFmt(String fmt) {
    var result = <Map<String, dynamic>>[];
    var endian = Endian.little; // Lua default is native; we default little.
    var i = 0;
    while (i < fmt.length) {
      var c = fmt[i];
      switch (c) {
        case '<': endian = Endian.little; i++; break;
        case '>': case '!': endian = Endian.big; i++; break;
        case '=': endian = Endian.host; i++; break;
        case ' ': i++; break;
        case 'b': case 'B':
        case 'h': case 'H':
        case 'l': case 'L':
        case 'j': case 'J':
        case 'f': case 'd': case 'n':
          result.add({'opt': c, 'size': _packOptSize(c, 0), 'endian': endian});
          i++;
          break;
        case 'i': case 'I':
          i++;
          var n = 4; // default int size
          if (i < fmt.length && fmt[i].codeUnitAt(0) >= 49 /* '1' */ &&
              fmt[i].codeUnitAt(0) <= 57 /* '9' */) {
            n = int.parse(fmt[i]);
            i++;
          }
          result.add({'opt': c, 'size': n, 'endian': endian});
          break;
        case 's':
          i++;
          var n = 8; // default size_t length prefix size
          if (i < fmt.length && fmt[i].codeUnitAt(0) >= 49 &&
              fmt[i].codeUnitAt(0) <= 57) {
            n = int.parse(fmt[i]);
            i++;
          }
          result.add({'opt': 's', 'size': n, 'endian': endian});
          break;
        case 'z':
          result.add({'opt': 'z', 'size': 0, 'endian': endian});
          i++;
          break;
        case 'x':
          result.add({'opt': 'x', 'size': 1, 'endian': endian});
          i++;
          break;
        default:
          i++;
          break;
      }
    }
    return result;
  }

  static void _packWriteInt(ByteData bd, int offset, int size, int value, Endian endian) {
    switch (size) {
      case 1: bd.setInt8(offset, value); break;
      case 2: bd.setInt16(offset, value, endian); break;
      case 4: bd.setInt32(offset, value, endian); break;
      case 8: bd.setInt64(offset, value, endian); break;
    }
  }

  static void _packWriteUint(ByteData bd, int offset, int size, int value, Endian endian) {
    switch (size) {
      case 1: bd.setUint8(offset, value); break;
      case 2: bd.setUint16(offset, value, endian); break;
      case 4: bd.setUint32(offset, value, endian); break;
      case 8: bd.setUint64(offset, value, endian); break;
    }
  }

  static int _packReadInt(ByteData bd, int offset, int size, Endian endian) {
    switch (size) {
      case 1: return bd.getInt8(offset);
      case 2: return bd.getInt16(offset, endian);
      case 4: return bd.getInt32(offset, endian);
      case 8: return bd.getInt64(offset, endian);
      default: return 0;
    }
  }

  static int _packReadUint(ByteData bd, int offset, int size, Endian endian) {
    switch (size) {
      case 1: return bd.getUint8(offset);
      case 2: return bd.getUint16(offset, endian);
      case 4: return bd.getUint32(offset, endian);
      case 8: return bd.getUint64(offset, endian);
      default: return 0;
    }
  }

// string.packsize (fmt)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.packsize
  static int _strPackSize(LuaState ls) {
    var fmt = ls.checkString(1)!;
    var ops = _parseFmt(fmt);
    var size = 0;
    for (var op in ops) {
      String opt = op['opt'];
      switch (opt) {
        case 'b': case 'B': case 'h': case 'H':
        case 'i': case 'I': case 'l': case 'L':
        case 'j': case 'J': case 'f': case 'd':
        case 'n': case 'x':
          size += op['size'] as int;
          break;
        case 's': case 'z':
          throw Exception("variable-size format '$opt' in packsize");
      }
    }
    ls.pushInteger(size);
    return 1;
  }

// string.pack (fmt, v1, v2, ···)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.pack
  static int _strPack(LuaState ls) {
    var fmt = ls.checkString(1)!;
    var ops = _parseFmt(fmt);

    // First pass: compute total size
    var argIdx = 2;
    var totalSize = 0;
    for (var op in ops) {
      String opt = op['opt'];
      int sz = op['size'];
      switch (opt) {
        case 'b': case 'B': case 'h': case 'H':
        case 'i': case 'I': case 'l': case 'L':
        case 'j': case 'J': case 'f': case 'd': case 'n':
          totalSize += sz;
          argIdx++;
          break;
        case 's':
          var str = ls.checkString(argIdx)!;
          totalSize += sz + utf8.encode(str).length;
          argIdx++;
          break;
        case 'z':
          var str = ls.checkString(argIdx)!;
          totalSize += utf8.encode(str).length + 1;
          argIdx++;
          break;
        case 'x':
          totalSize += 1;
          break;
      }
    }

    // Second pass: write
    var buf = Uint8List(totalSize);
    var bd = ByteData.view(buf.buffer);
    var offset = 0;
    argIdx = 2;
    for (var op in ops) {
      String opt = op['opt'];
      int sz = op['size'];
      Endian endian = op['endian'];
      switch (opt) {
        case 'b': case 'h': case 'i': case 'l': case 'j':
          _packWriteInt(bd, offset, sz, ls.checkInteger(argIdx)!, endian);
          offset += sz;
          argIdx++;
          break;
        case 'B': case 'H': case 'I': case 'L': case 'J':
          _packWriteUint(bd, offset, sz, ls.checkInteger(argIdx)!, endian);
          offset += sz;
          argIdx++;
          break;
        case 'f':
          bd.setFloat32(offset, ls.checkNumber(argIdx)!, endian);
          offset += 4;
          argIdx++;
          break;
        case 'd': case 'n':
          bd.setFloat64(offset, ls.checkNumber(argIdx)!, endian);
          offset += 8;
          argIdx++;
          break;
        case 's':
          var strBytes = utf8.encode(ls.checkString(argIdx)!);
          _packWriteUint(bd, offset, sz, strBytes.length, endian);
          offset += sz;
          buf.setRange(offset, offset + strBytes.length, strBytes);
          offset += strBytes.length;
          argIdx++;
          break;
        case 'z':
          var strBytes = utf8.encode(ls.checkString(argIdx)!);
          buf.setRange(offset, offset + strBytes.length, strBytes);
          offset += strBytes.length;
          buf[offset] = 0;
          offset++;
          argIdx++;
          break;
        case 'x':
          buf[offset] = 0;
          offset++;
          break;
      }
    }

    ls.pushString(String.fromCharCodes(buf));
    return 1;
  }

// string.unpack (fmt, s [, pos])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.unpack
  static int _strUnpack(LuaState ls) {
    var fmt = ls.checkString(1)!;
    var s = ls.checkString(2)!;
    var pos = ls.optInteger(3, 1)! - 1; // convert 1-based to 0-based
    var ops = _parseFmt(fmt);
    var bytes = Uint8List.fromList(s.codeUnits);
    var bd = ByteData.view(bytes.buffer);
    var offset = pos;
    var nResults = 0;

    for (var op in ops) {
      String opt = op['opt'];
      int sz = op['size'];
      Endian endian = op['endian'];
      switch (opt) {
        case 'b': case 'h': case 'i': case 'l': case 'j':
          ls.pushInteger(_packReadInt(bd, offset, sz, endian));
          offset += sz;
          nResults++;
          break;
        case 'B': case 'H': case 'I': case 'L': case 'J':
          ls.pushInteger(_packReadUint(bd, offset, sz, endian));
          offset += sz;
          nResults++;
          break;
        case 'f':
          ls.pushNumber(bd.getFloat32(offset, endian));
          offset += 4;
          nResults++;
          break;
        case 'd': case 'n':
          ls.pushNumber(bd.getFloat64(offset, endian));
          offset += 8;
          nResults++;
          break;
        case 's':
          var len = _packReadUint(bd, offset, sz, endian);
          offset += sz;
          ls.pushString(utf8.decode(bytes.sublist(offset, offset + len)));
          offset += len;
          nResults++;
          break;
        case 'z':
          var end = offset;
          while (end < bytes.length && bytes[end] != 0) {
            end++;
          }
          ls.pushString(utf8.decode(bytes.sublist(offset, end)));
          offset = end + 1; // skip null terminator
          nResults++;
          break;
        case 'x':
          offset++;
          break;
      }
    }

    // Lua's string.unpack also returns the position after the last read item
    ls.pushInteger(offset + 1); // back to 1-based
    return nResults + 1;
  }

/* STRING FORMAT */

// string.format (formatstring, ···)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.format
  static int _strFormat(LuaState ls) {
    var fmtStr = ls.checkString(1)!;
    if (fmtStr.length <= 1 || !fmtStr.contains('%')) {
      ls.pushString(fmtStr);
      return 1;
    }

    if (useFastFormat) {
      return _strFormatFast(ls, fmtStr);
    }

    var argIdx = 1;
    var arr = parseFmtStr(fmtStr);

    for (var i = 0; i < arr.length; i++) {
      if (arr[i]![0] == '%') {
        if (arr[i] == "%%") {
          arr[i] = "%";
        } else {
          argIdx += 1;
          arr[i] = _fmtArg(arr[i]!, ls, argIdx);
        }
      }
    }

    ls.pushString(arr.join());
    return 1;
  }

  /// Optimised string.format: caches the parsed template and avoids the
  /// [sprintf] package for common specifiers.
  static int _strFormatFast(LuaState ls, String fmtStr) {
    // --- cached parse -------------------------------------------------------
    var segments = _fmtCache[fmtStr];
    if (segments == null) {
      segments = parseFmtStr(fmtStr);
      if (_fmtCache.length >= _fmtCacheMaxSize) _fmtCache.clear();
      _fmtCache[fmtStr] = segments;
    }

    // --- format into StringBuffer -------------------------------------------
    final buf = StringBuffer();
    var argIdx = 1;

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i]!;
      if (seg.isEmpty || seg[0] != '%') {
        buf.write(seg);
      } else if (seg == '%%') {
        buf.write('%');
      } else {
        argIdx++;
        buf.write(_fmtArgFast(seg, ls, argIdx));
      }
    }

    ls.pushString(buf.toString());
    return 1;
  }

  /// Formats a single argument, using inline fast paths for the most common
  /// specifiers and falling back to [sprintf] for complex/rare ones.
  static String? _fmtArgFast(String tag, LuaState ls, int argIdx) {
    final spec = tag[tag.length - 1];

    // --- fast path: bare %d / %i / %s / %c (length == 2, no flags/width) ----
    if (tag.length == 2) {
      switch (spec) {
        case 'd': case 'i': case 'u':
          return ls.toInteger(argIdx).toString();
        case 's':
          return ls.toString2(argIdx);
        case 'c':
          return String.fromCharCode(ls.toInteger(argIdx));
        case 'f':
          return ls.toNumber(argIdx).toStringAsFixed(6);
      }
    }

    // --- fast path: integer with optional width/zero-pad --------------------
    if (spec == 'd' || spec == 'i' || spec == 'u') {
      final fast = _fastIntFormat(tag, ls.toInteger(argIdx));
      if (fast != null) return fast;
    }

    // --- fallback to sprintf for everything else ----------------------------
    return _fmtArg(tag, ls, argIdx);
  }

  /// Handles `%[flags][width]d` without [sprintf].
  ///
  /// Returns `null` if the format is too complex (precision, `+`, `#`, etc.)
  /// and needs the full [sprintf] path.
  static String? _fastIntFormat(String tag, int value) {
    var i = 1; // skip %
    final end = tag.length - 1; // before specifier char

    var leftAlign = false;
    var zeroPad = false;

    // flags
    while (i < end) {
      final c = tag.codeUnitAt(i);
      if (c == 0x2D /* - */) { leftAlign = true; i++; }
      else if (c == 0x30 /* 0 */) { zeroPad = true; i++; }
      else if (c == 0x20 || c == 0x2B || c == 0x23) { return null; } // ' +#'
      else { break; }
    }

    // width
    var width = 0;
    while (i < end) {
      final cu = tag.codeUnitAt(i);
      if (cu >= 0x30 && cu <= 0x39) {
        width = width * 10 + (cu - 0x30);
        i++;
      } else {
        break;
      }
    }

    // anything left (e.g. `.5d`) means precision → bail
    if (i < end) return null;

    var s = value.toString();

    if (width > 0 && s.length < width) {
      if (leftAlign) {
        s = s.padRight(width);
      } else if (zeroPad && value >= 0) {
        s = s.padLeft(width, '0');
      } else if (zeroPad /* && value < 0 */) {
        s = '-${s.substring(1).padLeft(width - 1, '0')}';
      } else {
        s = s.padLeft(width);
      }
    }

    return s;
  }

  static List<String?> parseFmtStr(String fmt) {
    if (fmt == "" || !fmt.contains('%')) {
      return [fmt];
    }

    var parsed = <String?>[];
    for (;;) {
      if (fmt == "") {
        break;
      }

      var match = tagPattern.firstMatch(fmt);
      if (match == null) {
        parsed.add(fmt);
        break;
      }

      var head = fmt.substring(0, match.start);
      var tag = fmt.substring(match.start, match.end);
      var tail = fmt.substring(match.end);

      if (head != "") {
        parsed.add(head);
      }
      parsed.add(tag);
      fmt = tail;
    }
    return parsed;
  }

  /// Lua %q: produce a string in double quotes with proper escaping.
  static String _fmtQuoted(String s) {
    final buf = StringBuffer('"');
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      switch (c) {
        case '\\': buf.write('\\\\'); break;
        case '"': buf.write('\\"'); break;
        case '\n': buf.write('\\n'); break;
        case '\r': buf.write('\\r'); break;
        case '\x00': buf.write('\\0'); break;
        case '\x1a': buf.write('\\26'); break;
        default: buf.write(c); break;
      }
    }
    buf.write('"');
    return buf.toString();
  }

  /// Original _fmtArg — used by the legacy (non-fast) path and as a fallback
  /// for specifiers that [_fmtArgFast] can't handle inline.
  static String? _fmtArg(String tag, LuaState ls, int argIdx) {
    switch (tag[tag.length - 1]) {
      // specifier
      case 'c': // character
        return String.fromCharCode(ls.toInteger(argIdx));
      case 'i':
        tag = "${tag.substring(0, tag.length - 1)}d"; // %i -> %d
        return sprintf(tag, [ls.toInteger(argIdx)]);
      case 'd':
      case 'o': // integer, octal
        return sprintf(tag, [ls.toInteger(argIdx)]);
      case 'u': // unsigned integer
        tag = "${tag.substring(0, tag.length - 1)}d"; // %u -> %d
        return sprintf(tag, [ls.toInteger(argIdx)]);
      case 'x':
      case 'X': // hex integer
        return sprintf(tag, [ls.toInteger(argIdx)]);
      case 'f': // float
      case 'e':
      case 'E': // scientific notation
      case 'g':
      case 'G': // general float
        return sprintf(tag, [ls.toNumber(argIdx)]);
      case 's': // string
        return sprintf(tag, [ls.toString2(argIdx)]);
      case 'q': // quoted string — Lua-specific escaping
        return _fmtQuoted(ls.toString2(argIdx) ?? 'nil');
      default:
        throw Exception("todo! tag=$tag");
    }
  }

/* PATTERN MATCHING */

// string.find (s, pattern [, init [, plain]])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.find
  static int _strFind(LuaState ls) {
    var s = ls.checkString(1)!;
    var sLen = s.length;
    var pattern = ls.checkString(2)!;
    var init = posRelat(ls.optInteger(3, 1)!, sLen);
    if (init < 1) {
      init = 1;
    } else if (init > sLen + 1) {
      /* start after string's end? */
      ls.pushNil();
      return 1;
    }
    var plain = ls.toBoolean(4);

    if (plain) {
      final idx = s.indexOf(pattern, init - 1);
      if (idx < 0) {
        ls.pushNil();
        return 1;
      }
      ls.pushInteger(idx + 1);
      ls.pushInteger(idx + pattern.length);
      return 2;
    }

    final m = LuaPattern.match(s, pattern, init - 1);
    if (m == null) {
      ls.pushNil();
      return 1;
    }
    ls.pushInteger(m.start + 1);
    ls.pushInteger(m.end);
    _pushCaptures(ls, m);
    return 2 + m.captures.length;
  }

  static List<int?> find(String s, String pattern, int init, bool plain) {
    final startOffset = init > 1 ? init - 1 : 0;
    int start;
    int matchLen;
    if (plain) {
      start = s.indexOf(pattern, startOffset);
      matchLen = pattern.length;
    } else {
      final m = LuaPattern.match(s, pattern, startOffset);
      if (m != null) {
        start = m.start;
        matchLen = m.end - m.start;
      } else {
        start = -1;
        matchLen = 0;
      }
    }
    final end = start + matchLen - 1;
    if (start >= 0) {
      return List<int?>.filled(2, null)
        ..[0] = start + 1
        ..[1] = end + 1;
    }
    return List<int?>.filled(2, null)
      ..[0] = start
      ..[1] = end;
  }

  /// Push each capture in [m] onto [ls]: strings as strings, position
  /// captures as integers (per Lua 5.3 semantics).
  static void _pushCaptures(LuaState ls, LuaPatternMatch m) {
    for (final c in m.captures) {
      if (c is StringCapture) {
        ls.pushString(c.value);
      } else if (c is PositionCapture) {
        ls.pushInteger(c.position);
      }
    }
  }

// string.match (s, pattern [, init])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.match
  static int _strMatch(LuaState ls) {
    var s = ls.checkString(1)!;
    var sLen = s.length;
    var pattern = ls.checkString(2)!;
    var init = posRelat(ls.optInteger(3, 1)!, sLen);
    if (init < 1) {
      init = 1;
    } else if (init > sLen + 1) {
      /* start after string's end? */
      ls.pushNil();
      return 1;
    }

    final m = LuaPattern.match(s, pattern, init - 1);
    if (m == null) {
      ls.pushNil();
      return 1;
    }
    if (m.captures.isEmpty) {
      // No explicit captures: push whole match.
      ls.pushString(s.substring(m.start, m.end));
      return 1;
    }
    _pushCaptures(ls, m);
    return m.captures.length;
  }

  /// Back-compat Dart helper. Returns captures as strings (position captures
  /// are stringified — the old API had no way to represent them). Returns
  /// `null` on no match; a single-element list with the whole match when the
  /// pattern has no capture groups.
  static List<String?>? match(String? s, String pattern, int init) {
    if (s == null) return null;
    final m = LuaPattern.match(s, pattern, init > 1 ? init - 1 : 0);
    if (m == null) return null;
    if (m.captures.isEmpty) {
      return [s.substring(m.start, m.end)];
    }
    return [
      for (final c in m.captures)
        if (c is StringCapture) c.value else (c as PositionCapture).position.toString(),
    ];
  }

// string.gsub (s, pattern, repl [, n])
// http://www.lua.org/manual/5.3/manual.html#pdf-string.gsub
  static int _strGsub(LuaState ls) {
    final s = ls.checkString(1)!;
    final pattern = ls.checkString(2)!;
    final replType = ls.type(3);
    final n = ls.optInteger(4, -1)!;

    if (replType == LuaType.luaString) {
      final repl = ls.checkString(3);
      final r = gsub(s, pattern, repl, n);
      ls.pushString(r[0]);
      ls.pushInteger(r[1]);
      return 2;
    }

    if (replType != LuaType.luaFunction && replType != LuaType.luaTable) {
      return ls.error2('string/function/table expected');
    }

    final buf = StringBuffer();
    var count = 0;
    var lastEnd = 0;
    for (final m in LuaPattern.allMatches(s, pattern)) {
      if (n >= 0 && count >= n) break;
      count++;
      buf.write(s.substring(lastEnd, m.start));

      // Determine the key/first-arg: first capture if present, else whole
      // match. Function replacement receives all captures (or the whole
      // match if the pattern has none).
      final wholeMatch = s.substring(m.start, m.end);
      if (replType == LuaType.luaFunction) {
        ls.pushValue(3);
        final nArgs = m.captures.isEmpty ? 1 : m.captures.length;
        if (m.captures.isEmpty) {
          ls.pushString(wholeMatch);
        } else {
          _pushCaptures(ls, m);
        }
        ls.call(nArgs, 1);
      } else {
        ls.pushValue(3);
        if (m.captures.isEmpty) {
          ls.pushString(wholeMatch);
        } else {
          final first = m.captures.first;
          if (first is StringCapture) {
            ls.pushString(first.value);
          } else {
            ls.pushInteger((first as PositionCapture).position);
          }
        }
        ls.getTable(-2);
      }

      // If result is nil/false, keep original match per Lua 5.3 semantics.
      if (ls.isNil(-1) ||
          (ls.type(-1) == LuaType.luaBoolean && !ls.toBoolean(-1))) {
        buf.write(wholeMatch);
      } else {
        final resultStr = ls.toStr(-1);
        if (resultStr == null) {
          return ls.error2(
              'invalid replacement value (a ${ls.typeName(ls.type(-1))})');
        }
        buf.write(resultStr);
      }
      ls.pop(replType == LuaType.luaFunction ? 1 : 2);
      lastEnd = m.end;
    }
    buf.write(s.substring(lastEnd));
    ls.pushString(buf.toString());
    ls.pushInteger(count);
    return 2;
  }

  /// Expand Lua-style back-references (%0, %1 … %9, %%) in [repl] using
  /// [m].
  static String _expandRepl(String repl, String src, LuaPatternMatch m) {
    final buf = StringBuffer();
    for (var i = 0; i < repl.length; i++) {
      final ch = repl[i];
      if (ch == '%' && i + 1 < repl.length) {
        final nxt = repl.codeUnitAt(i + 1);
        if (nxt == 0x25 /* '%' */) {
          buf.write('%');
          i++;
        } else if (nxt >= 0x30 /* '0' */ && nxt <= 0x39 /* '9' */) {
          final idx = nxt - 0x30;
          if (idx == 0) {
            buf.write(src.substring(m.start, m.end));
          } else if (idx <= m.captures.length) {
            final c = m.captures[idx - 1];
            if (c is StringCapture) {
              buf.write(c.value);
            } else {
              buf.write((c as PositionCapture).position);
            }
          } else if (idx == 1 && m.captures.isEmpty) {
            // Lua allows %1 with a pattern that has no captures to mean the
            // whole match.
            buf.write(src.substring(m.start, m.end));
          } else {
            throw LuaPatternError(
                'invalid capture index %$idx in replacement string');
          }
          i++;
        } else {
          throw LuaPatternError(
              "invalid use of '%' in replacement string");
        }
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  /// String-replacement gsub. Returns `[result, count]`.
  static List<dynamic> gsub(String? s, String pattern, String? repl, int n) {
    if (s == null) return ['', 0];
    if (n == 0) return [s, 0];
    final replacement = repl ?? '';
    final buf = StringBuffer();
    var count = 0;
    var lastEnd = 0;
    for (final m in LuaPattern.allMatches(s, pattern)) {
      if (n >= 0 && count >= n) break;
      count++;
      buf.write(s.substring(lastEnd, m.start));
      buf.write(_expandRepl(replacement, s, m));
      lastEnd = m.end;
    }
    buf.write(s.substring(lastEnd));
    return [buf.toString(), count];
  }

// string.gmatch (s, pattern)
// http://www.lua.org/manual/5.3/manual.html#pdf-string.gmatch
  static int _strGmatch(LuaState ls) {
    final s = ls.checkString(1)!;
    final pattern = ls.checkString(2)!;
    final iter = LuaPattern.allMatches(s, pattern).iterator;

    int gmatchAux(LuaState ls) {
      if (!iter.moveNext()) return 0;
      final m = iter.current;
      if (m.captures.isEmpty) {
        ls.pushString(s.substring(m.start, m.end));
        return 1;
      }
      _pushCaptures(ls, m);
      return m.captures.length;
    }

    ls.pushDartFunction(gmatchAux);
    return 1;
  }

/* translate a relative string position: negative means back from end */
  static int posRelat(int pos, int len) {
    if (pos >= 0) {
      return pos;
    } else if (-pos > len) {
      return 0;
    } else {
      return len + pos + 1;
    }
  }
}
