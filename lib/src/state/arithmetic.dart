import 'dart:math' as math;
import '../api/lua_type.dart';
import '../number/lua_math.dart';
import 'lua_state_impl.dart';
import 'lua_value.dart';

class Arithmetic {
  /// Enables an inline numeric fast path before the generic coercion and
  /// metamethod machinery. Switchable for performance comparisons.
  static bool useNumericFastPath = true;

  static final _integerOps = <Function?>[
    (a, b) => a + b, // lua_op_add
    (a, b) => a - b, // lua_op_sub
    (a, b) => a * b, // lua_op_mul
    LuaMath.iFloorMod, // lua_op_mod
    null, // lua_op_pow
    null, // lua_op_div
    LuaMath.iFloorDiv, // lua_op_idiv
    (a, b) => a & b, // lua_op_band
    (a, b) => a | b, // lua_op_bor
    (a, b) => a ^ b, // lua_op_bxor
    LuaMath.shiftLeft, // lua_op_shl
    LuaMath.shiftRight, // lua_op_shr
    (a, b) => -a, // lua_op_unm
    (a, b) => ~a, // lua_op_bnot
  ];

  static final _floatOps = <Function?>[
    (a, b) => a + b, // lua_op_add
    (a, b) => a - b, // lua_op_sub
    (a, b) => a * b, // lua_op_mul
    LuaMath.floorMod, // lua_op_mod
    math.pow, // lua_op_pow
    (a, b) => a / b, // lua_op_div
    LuaMath.floorDiv, // lua_op_idiv
    null, // lua_op_band
    null, // lua_op_bor
    null, // lua_op_bxor
    null, // lua_op_shl
    null, // lua_op_shr
    (a, b) => -a, // lua_op_unm
    null, // lua_op_bnot
  ];

  static final _metamethods = [
    "__add",
    "__sub",
    "__mul",
    "__mod",
    "__pow",
    "__div",
    "__idiv",
    "__band",
    "__bor",
    "__bxor",
    "__shl",
    "__shr",
    "__unm",
    "__bnot"
  ];

  static Object? arith(Object? a, Object? b, ArithOp op, LuaStateImpl ls) {
    // Arithmetic-heavy Lua normally reaches here with numbers already in the
    // registers. Avoid function-table lookup, dynamic Function.call, and the
    // more general string-coercion checks in that overwhelmingly common case.
    if (useNumericFastPath && a is num && b is num) {
      final bothInts = a is int && b is int;
      switch (op) {
        case ArithOp.luaOpAdd:
          return bothInts ? a + b : a.toDouble() + b.toDouble();
        case ArithOp.luaOpSub:
          return bothInts ? a - b : a.toDouble() - b.toDouble();
        case ArithOp.luaOpMul:
          return bothInts ? a * b : a.toDouble() * b.toDouble();
        case ArithOp.luaOpPow:
          return math.pow(a.toDouble(), b.toDouble());
        case ArithOp.luaOpDiv:
          return a.toDouble() / b.toDouble();
        default:
          break;
      }
    }

    Function? integerFunc = _integerOps[op.index];
    Function? floatFunc = _floatOps[op.index];

    if (floatFunc == null) {
      // bitwise
      int? x = LuaValue.otoInteger(a);
      if (x != null) {
        int? y = LuaValue.otoInteger(b);
        if (y != null) {
          return integerFunc!.call(x, y);
        }
      }
    } else {
      // arith
      if (integerFunc != null) {
        // add,sub,mul,mod,idiv,unm
        if (a is int && b is int) {
          return integerFunc.call(a, b);
        }
      }
      double? x = LuaValue.toFloat(a);
      if (x != null) {
        double? y = LuaValue.toFloat(b);
        if (y != null) {
          return floatFunc.call(x, y);
        }
      }
    }
    Object? mm = ls.getMetamethod(a, b, _metamethods[op.index]);
    if (mm != null) {
      return ls.callMetamethod(a, b, mm);
    }

    // Fix #33: Include line number in error message
    throw Exception(ls.formatError(
        "attempt to perform arithmetic on a ${LuaValue.typeName(a)} value"));
  }
}
