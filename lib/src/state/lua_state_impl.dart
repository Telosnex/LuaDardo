import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lua_dardo_plus/src/state/lua_userdata.dart';
import 'package:lua_dardo_plus/src/stdlib/os_lib.dart';
import '../platform/platform.dart';

import '../stdlib/math_lib.dart';
import '../stdlib/package_lib.dart';
import '../stdlib/string_lib.dart';
import '../stdlib/table_lib.dart';
import '../stdlib/coroutine_lib.dart';
import 'package:sprintf/sprintf.dart';

import '../number/lua_number.dart';
import '../stdlib/basic_lib.dart';
import '../api/lua_state.dart';
import '../api/lua_type.dart';
import '../api/lua_vm.dart';
import '../api/lua_debug.dart';
import '../binchunk/binary_chunk.dart';
import '../compiler/compiler.dart';
import '../compiler/codegen/exp_processor.dart';
import '../vm/fpb.dart';
import '../vm/instruction.dart';
import '../vm/instructions.dart';
import '../vm/opcodes.dart';
import 'arithmetic.dart';
import 'comparison.dart';
import 'lua_stack.dart';
import 'lua_table.dart';
import 'lua_value.dart';
import 'closure.dart';
import 'lua_error.dart';
import 'upvalue_holder.dart';

/// Global thread ID counter
int _threadIdCounter = 0;

/// Generates a new unique thread ID
int _genThreadId() => ++_threadIdCounter;

class LuaStateImpl implements LuaState, LuaVM {
  /// Controls the bytecode dispatch strategy.
  ///
  /// When `false` (default), uses the original indirect-function dispatch
  /// via [OpCode.action]. When `true`, uses a switch on the raw opcode
  /// integer, which compiles to a jump table and avoids the [OpCode]
  /// lookup, the `Function.call()` indirection, and the `name == "RETURN"`
  /// string comparison on every instruction.
  ///
  /// Toggle this from performance benchmarks; it is **not** checked per
  /// instruction — only once per [_runLuaClosure] invocation.
  static bool useSwitchDispatch = false;

  /// Executes common bytecodes against a cached register frame, bypassing the
  /// public stack API and the per-opcode LuaVM dispatch layer.
  static bool useRegisterExecution = true;

  /// Transfers fixed-arity calls directly between register frames.
  static bool useRegisterCalls = true;

  /// Extends direct register calls to variable-result calls.
  static bool useOpenResultRegisterCalls = true;

  /// Inlines numeric arithmetic and plain-table reads in the register tier.
  static bool useInlineRegisterFastPaths = true;

  /// Handles upvalues, table construction, iteration, and returns in registers.
  static bool useExtendedRegisterFastPaths = true;

  /// Advances the built-in ipairs iterator directly from TFORCALL.
  static bool useDirectIPairsIteration = true;

  /// Executes read-only virtual-triple consumers without a Lua call frame.
  static bool useInlineVirtualTripleConsumers = true;

  /// Reuses completed register call frames without clearing overwritten slots.
  static bool useRegisterCallFramePool = true;

  /// Executes nested Lua calls on one Dart interpreter loop instead of
  /// recursively entering [_runLuaClosure] for every Lua frame.
  static bool useIterativeRegisterCalls = true;

  /// Collects dynamic opcode and adjacent-opcode frequencies in the register
  /// interpreter. Disabled by default because the per-instruction counters are
  /// intentionally diagnostic rather than benchmark overhead.
  static bool collectRegisterOpcodeProfile = false;
  static final List<int> _registerOpcodeCounts =
      List<int>.filled(opCodes.length, 0);
  static final List<int> _registerOpcodePairCounts =
      List<int>.filled(opCodes.length * opCodes.length, 0);
  static final Map<Prototype, int> _registerLuaCallCounts = <Prototype, int>{};
  static final Map<DartFunction, int> _registerNativeCallCounts =
      <DartFunction, int>{};
  static final Expando<bool> _virtualTripleConsumers = Expando<bool>();

  /// Clears all register-interpreter opcode profiling counters.
  static void resetRegisterOpcodeProfile() {
    _registerOpcodeCounts.fillRange(0, _registerOpcodeCounts.length, 0);
    _registerOpcodePairCounts.fillRange(0, _registerOpcodePairCounts.length, 0);
    _registerLuaCallCounts.clear();
    _registerNativeCallCounts.clear();
  }

  /// Formats the most frequent dynamic opcodes and adjacent opcode pairs.
  static String registerOpcodeProfileReport({int top = 20}) {
    String formatCount(int count, int total) =>
        '${count.toString().padLeft(12)}  ${(count * 100 / total).toStringAsFixed(2).padLeft(6)}%';

    final total = _registerOpcodeCounts.fold<int>(0, (sum, n) => sum + n);
    if (total == 0) return 'Register opcode profile: no samples';
    final opcodeOrder = List<int>.generate(opCodes.length, (i) => i)
      ..sort((a, b) =>
          _registerOpcodeCounts[b].compareTo(_registerOpcodeCounts[a]));
    final pairOrder = List<int>.generate(
        _registerOpcodePairCounts.length, (i) => i)
      ..sort((a, b) =>
          _registerOpcodePairCounts[b].compareTo(_registerOpcodePairCounts[a]));
    final pairTotal =
        _registerOpcodePairCounts.fold<int>(0, (sum, n) => sum + n);
    final limit = math.min(top, opCodes.length);
    final pairLimit = math.min(top, pairOrder.length);
    final out = StringBuffer('Register opcode profile ($total instructions)\n')
      ..writeln('Opcodes:');
    for (int rank = 0; rank < limit; rank++) {
      final opcode = opcodeOrder[rank];
      final count = _registerOpcodeCounts[opcode];
      if (count == 0) break;
      out.writeln(
          '  ${opCodes[opcode].name.padRight(12)} ${formatCount(count, total)}');
    }
    out.writeln('Adjacent pairs:');
    for (int rank = 0; rank < pairLimit; rank++) {
      final pair = pairOrder[rank];
      final count = _registerOpcodePairCounts[pair];
      if (count == 0) break;
      final first = pair ~/ opCodes.length;
      final second = pair % opCodes.length;
      out.writeln(
          '  ${(opCodes[first].name + ' → ' + opCodes[second].name).padRight(25)} '
          '${formatCount(count, pairTotal)}');
    }
    final luaCalls = _registerLuaCallCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final nativeCalls = _registerNativeCallCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    out.writeln('Lua call targets:');
    for (final entry in luaCalls.take(top)) {
      final proto = entry.key;
      out.writeln('  lines ${proto.lineDefined}-${proto.lastLineDefined} '
          'code=${proto.code.length} params=${proto.numParams} '
          '${entry.value.toString().padLeft(12)}');
    }
    out.writeln('Native call targets:');
    for (final entry in nativeCalls.take(top)) {
      out.writeln('  ${entry.key.toString().padRight(40)} '
          '${entry.value.toString().padLeft(12)}');
    }
    return out.toString().trimRight();
  }

  /// Controls the stack representation.
  ///
  /// When `true` (default), [LuaStack] uses a fixed-capacity array with an
  /// explicit top pointer — `push` is a single indexed write, `pop` a single
  /// read + null, and `popN` produces one list instead of three.
  /// When `false`, the original growable-list behaviour is used (benchmark
  /// baseline).
  static bool useFixedStack = true;

  /// Copies Lua-call arguments directly between fixed stack frames.
  static bool useDirectCallTransfer = true;

  /// Copies Lua return values directly between fixed stack frames.
  static bool useDirectResultTransfer = true;

  /// Creates a [LuaStack] respecting the current [useFixedStack] flag.
  static LuaStack _newStack([int capacity = 40]) {
    return useFixedStack ? LuaStack(capacity) : LuaStack.growable();
  }

  LuaStack? _stack = _newStack();
  final List<LuaStack> _registerCallFrames = <LuaStack>[];
  final Map<Prototype, List<Object?>> _virtualConsumerScratch =
      <Prototype, List<Object?>>{};
  int _registerProfilePreviousOpcode = -1;

  LuaStack _acquireRegisterCallFrame(int capacity) {
    if (useRegisterCallFramePool) {
      for (int i = _registerCallFrames.length - 1; i >= 0; i--) {
        final frame = _registerCallFrames[i];
        if (frame.slots.length >= capacity) {
          _registerCallFrames.removeAt(i);
          return frame;
        }
      }
    }
    return _newStack(capacity);
  }

  void _releaseRegisterCallFrame(LuaStack frame) {
    if (!useRegisterCallFramePool || !useFixedStack) return;
    frame.prepareForCallReuse();
    _registerCallFrames.add(frame);
  }

  /// Registry table
  LuaTable? registry = LuaTable(0, 0);

  /// Thread status for coroutines
  ThreadStatus status = ThreadStatus.luaOk;

  /// Debug hook list
  final List<HookContext> hookList = [];

  /// Unique thread ID
  int id = 0;

  LuaStateImpl() {
    registry!.put(luaRidxGlobals, LuaTable(0, 0));
    LuaStack stack = _newStack();
    stack.state = this;
    _pushLuaStack(stack);
    id = _genThreadId();
    _updateThreadCache(id);
  }

  /// Constructor for creating a new thread (coroutine) that shares the registry
  LuaStateImpl.newThread(LuaTable registry) {
    this.registry = registry;
    LuaStack stack = _newStack();
    stack.state = this;
    _pushLuaStack(stack);
    id = _genThreadId();
    _updateThreadCache(id);
  }

  /// Updates the thread cache with this thread
  void _updateThreadCache(int threadId) {
    // Store weak reference to this thread in registry
    // This allows threads to be garbage collected when no longer referenced
  }

  /// 压入调用栈帧
  void _pushLuaStack(LuaStack newTop) {
    newTop.prev = this._stack;
    this._stack = newTop;
  }

  void _popLuaStack() {
    LuaStack top = this._stack!;
    this._stack = top.prev;
    top.prev = null;
  }

  /* metatable */
  LuaTable? _getMetatable(Object? val) {
    if (val is LuaTable) {
      return val.metatable;
    }
    // Fix #36: Support per-instance metatable for Userdata
    if (val is Userdata) {
      return val.metatable;
    }
    String key = "_MT${LuaValue.typeOf(val)}";
    Object? mt = registry!.get(key);
    return mt != null ? (mt as LuaTable) : null;
  }

  void _setMetatable(Object? val, LuaTable? mt) {
    if (val is LuaTable) {
      val.metatable = mt;
      return;
    }
    // Fix #36: Support per-instance metatable for Userdata
    if (val is Userdata) {
      val.metatable = mt;
      return;
    }
    String key = "_MT${LuaValue.typeOf(val)}";
    registry!.put(key, mt);
  }

  Object? _getMetafield(Object? val, String fieldName) {
    LuaTable? mt = _getMetatable(val);
    return mt != null ? mt.get(fieldName) : null;
  }

  Object? getMetamethod(Object? a, Object? b, String mmName) {
    Object? mm = _getMetafield(a, mmName);
    if (mm == null) {
      mm = _getMetafield(b, mmName);
    }
    return mm;
  }

  Object? callMetamethod(Object? a, Object? b, Object mm) {
    _stack!.push(mm);
    _stack!.push(a);
    _stack!.push(b);
    call(2, 1);
    return _stack!.pop();
  }

  //**************************************************
  //******************* LuaState *********************
  //**************************************************

  /// Get the raw Dart object at [idx] on the Lua stack.
  /// Used internally by stdlib for operations that need the underlying value.
  Object? getRawValue(int idx) {
    return _stack!.get(idx);
  }

  @override
  int absIndex(int idx) {
    return _stack!.absIndex(idx);
  }

  @override
  bool checkStack(int n) {
    return true; // TODO
  }

  @override
  void copy(int fromIdx, int toIdx) {
    _stack!.set(toIdx, _stack!.get(fromIdx));
  }

  @override
  int getTop() {
    return _stack!.top();
  }

  @override
  void insert(int idx) {
    rotate(idx, 1);
  }

  @override
  bool isFunction(int idx) {
    return type(idx) == LuaType.luaFunction;
  }

  @override
  bool isInteger(int idx) {
    return _stack!.get(idx) is int;
  }

  @override
  bool isNil(int idx) {
    return type(idx) == LuaType.luaNil;
  }

  @override
  bool isNone(int idx) {
    return type(idx) == LuaType.luaNone;
  }

  @override
  bool isNoneOrNil(int idx) {
    LuaType t = type(idx);
    return t == LuaType.luaNone || t == LuaType.luaNil;
  }

  @override
  bool isNumber(int idx) {
    return toNumberX(idx) != null;
  }

  @override
  bool isString(int idx) {
    LuaType t = type(idx);
    return t == LuaType.luaString || t == LuaType.luaNumber;
  }

  @override
  bool isTable(int idx) {
    return type(idx) == LuaType.luaTable;
  }

  @override
  bool isThread(int idx) {
    return type(idx) == LuaType.luaThread;
  }

  @override
  bool isBoolean(int idx) {
    return type(idx) == LuaType.luaBoolean;
  }

  @override
  bool isUserdata(int idx) {
    return type(idx) == LuaType.luaUserdata;
  }

  @override
  void pop(int n) {
    _stack!.popDiscard(n);
  }

  @override
  void pushInteger(int? n) {
    _stack!.push(n);
  }

  @override
  void pushNil() {
    _stack!.push(null);
  }

  @override
  void pushNumber(double n) {
    _stack!.push(n);
  }

  @override
  void pushString(String? s) {
    _stack!.push(s);
  }

  @override
  void pushValue(int idx) {
    _stack!.push(_stack!.get(idx));
  }

  @override
  void pushBoolean(bool b) {
    _stack!.push(b);
  }

  @override
  void remove(int idx) {
    rotate(idx, -1);
    pop(1);
  }

  @override
  void replace(int idx) {
    _stack!.set(idx, _stack!.pop());
  }

  @override
  void rotate(int idx, int n) {
    int t = _stack!.top() - 1; /* end of stack segment being rotated */
    int p = _stack!.absIndex(idx) - 1; /* start of segment */
    int m = n >= 0 ? t - n : p - n - 1; /* end of prefix */

    _stack!.reverse(p, m); /* reverse the prefix with length 'n' */
    _stack!.reverse(m + 1, t); /* reverse the suffix */
    _stack!.reverse(p, t); /* reverse the entire segment */
  }

  @override
  void setTop(int idx) {
    int newTop = _stack!.absIndex(idx);
    if (newTop < 0) {
      // Fix #33: Include line number in error message
      throw Exception(_stack!.formatError("stack underflow!"));
    }
    _stack!.setTopDirect(newTop);
  }

  @override
  int toInteger(int idx) {
    int? i = toIntegerX(idx);
    return i == null ? 0 : i;
  }

  @override
  int? toIntegerX(int idx) {
    Object? val = _stack!.get(idx);
    if (val is int) return val;
    if (val is double) {
      if (val == val.toInt().toDouble()) return val.toInt();
      return null;
    }
    if (val is String) {
      var i = int.tryParse(val);
      if (i != null) return i;
      var d = double.tryParse(val);
      if (d != null && d == d.toInt().toDouble()) return d.toInt();
      return null;
    }
    return null;
  }

  @override
  double toNumber(int idx) {
    double? n = toNumberX(idx);
    return n == null ? 0 : n;
  }

  @override
  double? toNumberX(int idx) {
    Object? val = _stack!.get(idx);
    if (val is num) {
      return val.toDouble();
    } else if (val is String) {
      // Lua 5.3: lua_tonumberx coerces strings to numbers.
      return double.tryParse(val) ?? (int.tryParse(val)?.toDouble());
    } else {
      return null;
    }
  }

  @override
  Userdata? toUserdata<T>(int idx) {
    Object? val = _stack!.get(idx);
    return val is Userdata ? val : null;
  }

  @override
  bool toBoolean(int idx) {
    return LuaValue.toBoolean(_stack!.get(idx));
  }

  @override
  LuaType type(int idx) {
    return _stack!.isValid(idx)
        ? LuaValue.typeOf(_stack!.get(idx))
        : LuaType.luaNone;
  }

  @override
  String typeName(LuaType tp) {
    switch (tp) {
      case LuaType.luaNone:
        return "no value";
      case LuaType.luaNil:
        return "nil";
      case LuaType.luaBoolean:
        return "boolean";
      case LuaType.luaNumber:
        return "number";
      case LuaType.luaString:
        return "string";
      case LuaType.luaTable:
        return "table";
      case LuaType.luaFunction:
        return "function";
      case LuaType.luaThread:
        return "thread";
      default:
        return "userdata";
    }
  }

  @override
  String? toStr(int idx) {
    Object? val = _stack!.get(idx);
    if (val is String) {
      return val;
    } else if (val is num) {
      return val.toString();
    } else {
      return null;
    }
  }

  @override
  void arith(ArithOp op) {
    Object? b = _stack!.pop();
    Object? a =
        op != ArithOp.luaOpUnm && op != ArithOp.luaOpBnot ? _stack!.pop() : b;
    Object? result = Arithmetic.arith(a, b, op, this);
    if (result != null) {
      _stack!.push(result);
    } else {
      // Fix #33: Include line number in error message
      throw Exception(_stack!
          .formatError("attempt to perform arithmetic on a non-number value"));
    }
  }

  @override
  bool compare(int idx1, int idx2, CmpOp op) {
    if (!_stack!.isValid(idx1) || !_stack!.isValid(idx2)) {
      return false;
    }

    Object? a = _stack!.get(idx1);
    Object? b = _stack!.get(idx2);
    switch (op) {
      case CmpOp.luaOpEq:
        return Comparison.eq(a, b, this);
      case CmpOp.luaOpLt:
        return Comparison.lt(a, b, this);
      case CmpOp.luaOpLe:
        return Comparison.le(a, b, this);
    }
  }

  @override
  void concat(int n) {
    if (n == 0) {
      _stack!.push("");
    } else if (n >= 2) {
      for (int i = 1; i < n; i++) {
        if (isString(-1) && isString(-2)) {
          String s2 = toStr(-1)!;
          String s1 = toStr(-2)!;
          pop(2);
          pushString(s1 + s2);
          continue;
        }

        Object? b = _stack!.pop();
        Object? a = _stack!.pop();
        Object? mm = getMetamethod(a, b, "__concat");
        if (mm != null) {
          _stack!.push(callMetamethod(a, b, mm));
          continue;
        }

        // Fix #33: Include line number in error message
        throw Exception(
            _stack!.formatError("attempt to concatenate non-string values"));
      }
    }
    // n == 1, do nothing
  }

  @override
  void len(int idx) {
    Object? val = _stack!.get(idx);
    if (val is String) {
      pushInteger(val.length);
      return;
    }

    Object? mm = getMetamethod(val, val, "__len");
    if (mm != null) {
      _stack!.push(callMetamethod(val, val, mm));
      return;
    }

    if (val is LuaTable) {
      pushInteger(val.length());
    } else {
      // Fix #33: Include line number in error message
      throw Exception(_stack!.formatError(
          "attempt to get length of a ${LuaValue.typeName(val)} value"));
    }
  }

  @override
  void createTable(int nArr, int nRec) {
    _stack!.push(LuaTable(nArr, nRec));
  }

  @override
  LuaType getField(int idx, String? k) {
    Object? t = _stack!.get(idx);
    return _getTable(t, k, false);
  }

  @override
  LuaType getI(int idx, int i) {
    Object? t = _stack!.get(idx);
    return _getTable(t, i, false);
  }

  @override
  LuaType getTable(int idx) {
    Object? t = _stack!.get(idx);
    Object? k = _stack!.pop();
    return _getTable(t, k, false);
  }

  /// [raw] 是否忽略元方法
  /// _setTable 同
  LuaType _getTable(Object? t, Object? k, bool raw) {
    if (t is LuaTable) {
      LuaTable tbl = t;
      Object? v = t.get(k);

      if (raw || v != null || !tbl.hasMetafield("__index")) {
        _stack!.push(v);
        return LuaValue.typeOf(v);
      }
    }

    if (!raw) {
      Object? mf = _getMetafield(t, "__index");
      if (mf != null) {
        if (mf is LuaTable) {
          return _getTable(mf, k, false);
        } else if (mf is Closure) {
          Object? v = callMetamethod(t, k, mf);
          _stack!.push(v);
          return LuaValue.typeOf(v);
        }
      }
    }
    // Fix #33: Include line number in error message
    throw Exception(_stack!
        .formatError("attempt to index a ${LuaValue.typeName(t)} value"));
  }

  @override
  void newTable() {
    createTable(0, 0);
  }

  @override
  Userdata newUserdata<T>() {
    var r = Userdata<T>();
    _stack!.push(r);
    return r;
  }

  @override
  void setField(int idx, String? k) {
    Object? t = _stack!.get(idx);
    Object? v = _stack!.pop();
    _setTable(t, k, v, false);
  }

  @override
  void setTable(int idx) {
    Object? t = _stack!.get(idx);
    Object? v = _stack!.pop();
    Object? k = _stack!.pop();
    _setTable(t, k, v, false);
  }

  @override
  void setI(int idx, int? i) {
    Object? t = _stack!.get(idx);
    Object? v = _stack!.pop();
    _setTable(t, i, v, false);
  }

  void _setTable(Object? t, Object? k, Object? v, bool raw) {
    if (t is LuaTable) {
      LuaTable tbl = t;
      if (raw || tbl.get(k) != null || !tbl.hasMetafield("__newindex")) {
        tbl.put(k, v);
        return;
      }
    }

    if (!raw) {
      Object? mf = _getMetafield(t, "__newindex");
      if (mf != null) {
        if (mf is LuaTable) {
          _setTable(mf, k, v, false);
          return;
        }
        if (mf is Closure) {
          _stack!.push(mf);
          _stack!.push(t);
          _stack!.push(k);
          _stack!.push(v);
          call(3, 0);
          return;
        }
      }
    }
    // Fix #33: Include line number in error message
    throw Exception(_stack!
        .formatError("attempt to index a ${LuaValue.typeName(t)} value"));
  }

  @override
  void call(int nArgs, int nResults) {
    Object? val = _stack!.get(-(nArgs + 1));
    Object? f = val is Closure ? val : null;

    if (f == null) {
      Object? mf = _getMetafield(val, "__call");
      if (mf != null && mf is Closure) {
        _stack!.push(f);
        insert(-(nArgs + 2));
        nArgs += 1;
        f = mf;
      }
    }

    if (f != null) {
      Closure c = f as Closure;
      if (c.proto != null) {
        _callLuaClosure(nArgs, nResults, c);
      } else {
        _callDartClosure(nArgs, nResults, c);
      }
    } else {
      // Fix #33: Include line number in error message
      throw Exception(
          _stack!.formatError("attempt to call a non-function value"));
    }
  }

  void _callLuaClosure(int nArgs, int nResults, Closure c) {
    int nRegs = c.proto!.maxStackSize;
    int nParams = c.proto!.numParams!;
    bool isVararg = c.proto!.isVararg == 1;

    // create new lua stack
    LuaStack newStack = _newStack(nRegs + 20);
    newStack.state = this;
    newStack.closure = c;

    // Pass args and remove the function from the caller frame.
    if (useDirectCallTransfer) {
      _stack!.transferCallTo(newStack, nArgs, nParams, isVararg);
    } else {
      List<Object?> funcAndArgs = _stack!.popN(nArgs + 1);
      newStack.pushN(funcAndArgs.sublist(1, funcAndArgs.length), nParams);
      if (nArgs > nParams && isVararg) {
        newStack.varargs = funcAndArgs.sublist(nParams + 1, funcAndArgs.length);
      }
    }

    // run closure
    _pushLuaStack(newStack);
    setTop(nRegs);
    _runLuaClosure();
    _popLuaStack();

    // Return results to the caller frame.
    if (nResults != 0) {
      if (useDirectResultTransfer) {
        newStack.transferResultsTo(_stack!, nRegs, nResults);
      } else {
        List<Object?> results = newStack.popN(newStack.top() - nRegs);
        _stack!.pushN(results, nResults);
      }
    }
  }

  void _callDartClosure(int nArgs, int nResults, Closure c) {
    // create new lua stack
    LuaStack newStack = _newStack();
    newStack.state = this;
    newStack.closure = c;

    // pass args, pop func
    if (nArgs > 0) {
      newStack.pushN(_stack!.popN(nArgs), nArgs);
    }
    _stack!.pop();

    // run closure
    _pushLuaStack(newStack);
    int r = c.dartFunc!.call(this);
    _popLuaStack();

    // return results
    if (nResults != 0) {
      List<Object?> results = newStack.popN(r);
      //stack.check(results.size())
      _stack!.pushN(results, nResults);
    }
  }

  void _runLuaClosure() {
    if (useRegisterExecution) {
      _runRegisterClosure();
      return;
    }

    // Optimised dispatch loop that replaces the original triple overhead
    // (array lookup → indirect Function.call → string comparison) with a
    // single `switch` on the raw 6-bit opcode. ~10% perf win.
    for (;;) {
      final int inst = fetch();
      switch (inst & 0x3F) {
        case 0:
          Instructions.move(inst, this);
          break;
        case 1:
          Instructions.loadK(inst, this);
          break;
        case 2:
          Instructions.loadKx(inst, this);
          break;
        case 3:
          Instructions.loadBool(inst, this);
          break;
        case 4:
          Instructions.loadNil(inst, this);
          break;
        case 5:
          Instructions.getUpval(inst, this);
          break;
        case 6:
          Instructions.getTabUp(inst, this);
          break;
        case 7:
          Instructions.getTable(inst, this);
          break;
        case 8:
          Instructions.setTabUp(inst, this);
          break;
        case 9:
          Instructions.setUpval(inst, this);
          break;
        case 10:
          Instructions.setTable(inst, this);
          break;
        case 11:
          Instructions.newTable(inst, this);
          break;
        case 12:
          Instructions.self(inst, this);
          break;
        case 13:
          Instructions.add(inst, this);
          break;
        case 14:
          Instructions.sub(inst, this);
          break;
        case 15:
          Instructions.mul(inst, this);
          break;
        case 16:
          Instructions.mod(inst, this);
          break;
        case 17:
          Instructions.pow(inst, this);
          break;
        case 18:
          Instructions.div(inst, this);
          break;
        case 19:
          Instructions.idiv(inst, this);
          break;
        case 20:
          Instructions.band(inst, this);
          break;
        case 21:
          Instructions.bor(inst, this);
          break;
        case 22:
          Instructions.bxor(inst, this);
          break;
        case 23:
          Instructions.shl(inst, this);
          break;
        case 24:
          Instructions.shr(inst, this);
          break;
        case 25:
          Instructions.unm(inst, this);
          break;
        case 26:
          Instructions.bnot(inst, this);
          break;
        case 27:
          Instructions.not(inst, this);
          break;
        case 28:
          Instructions.length(inst, this);
          break;
        case 29:
          Instructions.concat(inst, this);
          break;
        case 30:
          Instructions.jmp(inst, this);
          break;
        case 31:
          Instructions.eq(inst, this);
          break;
        case 32:
          Instructions.lt(inst, this);
          break;
        case 33:
          Instructions.le(inst, this);
          break;
        case 34:
          Instructions.test(inst, this);
          break;
        case 35:
          Instructions.testSet(inst, this);
          break;
        case 36:
          Instructions.call(inst, this);
          break;
        case 37:
          Instructions.tailCall(inst, this);
          break;
        case 38:
          Instructions.return_(inst, this);
          return;
        case 39:
          Instructions.forLoop(inst, this);
          break;
        case 40:
          Instructions.forPrep(inst, this);
          break;
        case 41:
          Instructions.tForCall(inst, this);
          break;
        case 42:
          Instructions.tForLoop(inst, this);
          break;
        case 43:
          Instructions.setList(inst, this);
          break;
        case 44:
          Instructions.closure(inst, this);
          break;
        case 45:
          Instructions.vararg(inst, this);
          break;
        case 46:
          break; // EXTRAARG — consumed by preceding instruction
      }
    }
  }

  /// Calls a closure from a fixed register range and writes fixed-count
  /// results back without staging function, arguments, and results above the
  /// caller's register window.
  bool _canConsumeVirtualTriple(Prototype proto) {
    final cached = _virtualTripleConsumers[proto];
    if (cached != null) return cached;
    if (proto.numParams != 1 || proto.isVararg == 1) {
      _virtualTripleConsumers[proto] = false;
      return false;
    }
    var readsParameter = false;
    for (final instruction in proto.code) {
      final opcode = instruction & 0x3F;
      final a = (instruction >> 6) & 0xFF;
      final b = (instruction >> 23) & 0x1FF;
      final c = (instruction >> 14) & 0x1FF;
      if (opcode == 7 && b == 0 && c > 0xFF) {
        final key = proto.constants[c & 0xFF];
        if (key is int && key >= 1 && key <= 3) {
          readsParameter = true;
          continue;
        }
      }
      if ((opcode == 0 && b == 0) ||
          (opcode >= 13 && opcode <= 24 && (b == 0 || c == 0)) ||
          (opcode >= 31 && opcode <= 33 && (b == 0 || c == 0)) ||
          a == 0 && opcode != 38) {
        _virtualTripleConsumers[proto] = false;
        return false;
      }
    }
    _virtualTripleConsumers[proto] = readsParameter;
    return readsParameter;
  }

  static final Object _virtualConsumerFailed = Object();

  Object? _executeVirtualTripleConsumer(Prototype proto, int length,
      Object? value1, Object? value2, Object? value3) {
    final registers = _virtualConsumerScratch.putIfAbsent(
        proto, () => List<Object?>.filled(proto.maxStackSize, null));
    registers[0] = virtualSmallTableMarkers[length - 1];
    final code = proto.code;
    final constants = proto.constants;
    var pc = 0;
    while (pc < code.length) {
      final instruction = code[pc++];
      final opcode = instruction & 0x3F;
      final a = (instruction >> 6) & 0xFF;
      final b = (instruction >> 23) & 0x1FF;
      final c = (instruction >> 14) & 0x1FF;
      switch (opcode) {
        case 0: // MOVE
          registers[a] = registers[b];
          break;
        case 1: // LOADK
          registers[a] = constants[instruction >> 14];
          break;
        case 3: // LOADBOOL
          registers[a] = b != 0;
          if (c != 0) pc++;
          break;
        case 4: // LOADNIL
          for (int i = a; i <= a + b; i++) registers[i] = null;
          break;
        case 7: // GETTABLE
          if (registers[b] is! VirtualSmallTableMarker) {
            return _virtualConsumerFailed;
          }
          final key = c > 0xFF ? constants[c & 0xFF] : registers[c];
          final marker = registers[b] as VirtualSmallTableMarker;
          registers[a] = key is int && key > marker.length
              ? null
              : switch (key) {
                  1 => value1,
                  2 => value2,
                  3 => value3,
                  _ => null,
                };
          break;
        case 13: // ADD
        case 14: // SUB
        case 15: // MUL
        case 17: // POW
        case 18: // DIV
          final left = b > 0xFF ? constants[b & 0xFF] : registers[b];
          final right = c > 0xFF ? constants[c & 0xFF] : registers[c];
          if (left is! num || right is! num) return _virtualConsumerFailed;
          final bothInts = left is int && right is int;
          registers[a] = switch (opcode) {
            13 => bothInts ? left + right : left.toDouble() + right.toDouble(),
            14 => bothInts ? left - right : left.toDouble() - right.toDouble(),
            15 => bothInts ? left * right : left.toDouble() * right.toDouble(),
            17 => math.pow(left.toDouble(), right.toDouble()),
            _ => left.toDouble() / right.toDouble(),
          };
          break;
        case 27: // NOT
          registers[a] = !LuaValue.toBoolean(registers[b]);
          break;
        case 30: // JMP
          pc += (instruction >> 14) - Instruction.maxArg_sbx;
          break;
        case 31: // EQ
        case 32: // LT
        case 33: // LE
          final left = b > 0xFF ? constants[b & 0xFF] : registers[b];
          final right = c > 0xFF ? constants[c & 0xFF] : registers[c];
          bool result;
          if (opcode == 31) {
            result = left == right;
          } else {
            if (left is! num || right is! num) {
              return _virtualConsumerFailed;
            }
            result = opcode == 32 ? left < right : left <= right;
          }
          if (result != (a != 0)) pc++;
          break;
        case 34: // TEST
          if (LuaValue.toBoolean(registers[a]) != (c != 0)) pc++;
          break;
        case 35: // TESTSET
          if (LuaValue.toBoolean(registers[b]) == (c != 0)) {
            registers[a] = registers[b];
          } else {
            pc++;
          }
          break;
        case 38: // RETURN
          final result = b == 2 ? registers[a] : _virtualConsumerFailed;
          registers.fillRange(0, registers.length, null);
          return result;
        default:
          return _virtualConsumerFailed;
      }
    }
    return _virtualConsumerFailed;
  }

  LuaTable _materializeVirtualTriple(LuaStack caller, int base) {
    final marker = caller.slots[base + 1] as VirtualSmallTableMarker;
    final table = LuaTable(marker.length, 0);
    for (int i = 1; i <= marker.length; i++) {
      table.put(i, caller.slots[base + 1 + i]);
    }
    return table;
  }

  int _callFixedRegisters(LuaStack caller, int base, int nArgs, int nResults,
      [int? resultBase]) {
    final value = caller.slots[base];
    if (value is! Closure) return 0;
    if (collectRegisterOpcodeProfile) {
      final proto = value.proto;
      if (proto != null) {
        _registerLuaCallCounts[proto] =
            (_registerLuaCallCounts[proto] ?? 0) + 1;
      } else if (value.dartFunc != null) {
        final function = value.dartFunc!;
        _registerNativeCallCounts[function] =
            (_registerNativeCallCounts[function] ?? 0) + 1;
      }
    }
    final destination = resultBase ?? base;
    final marker = caller.slots[base + 1];
    final hasVirtualTriple = nArgs == 1 && marker is VirtualSmallTableMarker;
    final consumeVirtualTriple = hasVirtualTriple &&
        value.proto != null &&
        _canConsumeVirtualTriple(value.proto!);
    if (hasVirtualTriple && !consumeVirtualTriple) {
      caller.slots[base + 1] = _materializeVirtualTriple(caller, base);
    } else if (consumeVirtualTriple &&
        useInlineVirtualTripleConsumers &&
        nResults == 1) {
      final result = _executeVirtualTripleConsumer(
          value.proto!,
          (marker as VirtualSmallTableMarker).length,
          caller.slots[base + 2],
          caller.slots[base + 3],
          caller.slots[base + 4]);
      if (!identical(result, _virtualConsumerFailed)) {
        caller.slots[destination] = result;
        return 1;
      }
    }

    final callee = _acquireRegisterCallFrame(
        value.proto == null ? 40 : value.proto!.maxStackSize + 20);
    callee.state = this;
    callee.closure = value;

    if (value.proto != null) {
      final proto = value.proto!;
      final nParams = proto.numParams!;
      callee.reserveCallArguments(nParams);
      final calleeSlots = callee.slots;
      for (int i = 0; i < nParams; i++) {
        calleeSlots[i] = i < nArgs ? caller.slots[base + i + 1] : null;
      }
      if (consumeVirtualTriple) {
        callee.virtualSmallTableLength =
            (marker as VirtualSmallTableMarker).length;
        callee.virtualTriple1 = caller.slots[base + 2];
        callee.virtualTriple2 = caller.slots[base + 3];
        callee.virtualTriple3 = caller.slots[base + 4];
      }
      if (proto.isVararg == 1 && nArgs > nParams) {
        callee.varargs = List<Object?>.generate(
          nArgs - nParams,
          (i) => caller.slots[base + nParams + i + 1],
          growable: false,
        );
      }

      callee.registerReturnDestination = destination;
      callee.registerReturnCount = nResults;
      callee.finishRegisterCallSetup(nParams, proto.maxStackSize);
      _pushLuaStack(callee);
      if (!useIterativeRegisterCalls) {
        _runLuaClosure();
        _finishRegisterLuaCall(callee);
        return 1;
      }
      return 2; // Lua frame pushed; the register trampoline will execute it.
    } else {
      callee.reserveCallArguments(nArgs);
      final calleeSlots = callee.slots;
      for (int i = 0; i < nArgs; i++) {
        calleeSlots[i] = caller.slots[base + i + 1];
      }
      _pushLuaStack(callee);
      final resultCount = value.dartFunc!.call(this);
      _popLuaStack();

      final resultStart = callee.top() - resultCount;
      if (nResults < 0) {
        final registerCount = caller.closure!.proto!.maxStackSize;
        caller.setTopDirect(registerCount + resultCount);
        final callerSlots = caller.slots;
        for (int i = 0; i < resultCount; i++) {
          callerSlots[registerCount + i] = callee.slots[resultStart + i];
        }
        caller.push(destination + 1); // open-result destination marker
      } else {
        for (int i = 0; i < nResults; i++) {
          caller.slots[destination + i] =
              i < resultCount ? callee.slots[resultStart + i] : null;
        }
      }
    }
    _releaseRegisterCallFrame(callee);
    return 1; // Native call completed synchronously.
  }

  void _finishRegisterLuaCall(LuaStack callee) {
    final caller = callee.prev!;
    final proto = callee.closure!.proto!;
    final destination = callee.registerReturnDestination;
    final nResults = callee.registerReturnCount;
    final available = callee.top() - proto.maxStackSize;
    if (nResults < 0) {
      final registerCount = caller.closure!.proto!.maxStackSize;
      caller.setTopDirect(registerCount + available);
      final callerSlots = caller.slots;
      for (int i = 0; i < available; i++) {
        callerSlots[registerCount + i] = callee.slots[proto.maxStackSize + i];
      }
      caller.push(destination + 1);
    } else {
      final callerSlots = caller.slots;
      for (int i = 0; i < nResults; i++) {
        callerSlots[destination + i] =
            i < available ? callee.slots[proto.maxStackSize + i] : null;
      }
    }
    _popLuaStack();
    _releaseRegisterCallFrame(callee);
  }

  /// Register-oriented execution tier for common bytecodes. Less common and
  /// semantically complex operations continue through their shared handlers.
  void _runRegisterClosure() {
    final root = _stack!;
    frameLoop:
    for (;;) {
      final stack = _stack!;
      // Complex handlers can grow the frame and replace its backing array, so
      // refresh this cache after every fallback through the stack API.
      var slots = stack.slots;
      final closure = stack.closure!;
      final upvalues = closure.upvals;
      final proto = closure.proto!;
      final code = proto.code;
      final constants = proto.constants;
      var pc = stack.pc;

      for (;;) {
        final inst = code[pc++];
        final opcode = inst & 0x3F;
        if (collectRegisterOpcodeProfile) {
          _registerOpcodeCounts[opcode]++;
          final previous = _registerProfilePreviousOpcode;
          if (previous >= 0) {
            _registerOpcodePairCounts[previous * opCodes.length + opcode]++;
          }
          _registerProfilePreviousOpcode = opcode;
        }
        final a = (inst >> 6) & 0xFF;
        final b = (inst >> 23) & 0x1FF;
        final c = (inst >> 14) & 0x1FF;
        switch (opcode) {
          case 0: // MOVE
            slots[a] = slots[b];
            break;
          case 1: // LOADK
            slots[a] = constants[inst >> 14];
            break;
          case 3: // LOADBOOL
            slots[a] = (b) != 0;
            if ((c) != 0) pc++;
            break;
          case 4: // LOADNIL
            final end = a + b;
            for (int register = a; register <= end; register++) {
              slots[register] = null;
            }
            break;
          case 5: // GETUPVAL
            if (useExtendedRegisterFastPaths) {
              final holder = upvalues[b];
              slots[a] = holder?.stack != null
                  ? holder!.stack!.slots[holder.index!]
                  : holder?.value;
            } else {
              stack.pc = pc;
              Instructions.getUpval(inst, this);
              pc = stack.pc;
              slots = stack.slots;
            }
            break;
          case 6: // GETTABUP
            if (useExtendedRegisterFastPaths) {
              final holder = upvalues[b];
              final table = holder?.stack != null
                  ? holder!.stack!.slots[holder.index!]
                  : holder?.value;
              final key = c > 0xFF ? constants[c & 0xFF] : slots[c];
              if (table is LuaTable) {
                final value = table.get(key);
                if (value != null || table.metatable == null) {
                  slots[a] = value;
                  break;
                }
              }
            }
            stack.pc = pc;
            Instructions.getTabUp(inst, this);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 7: // GETTABLE
            final table = slots[b];
            final key = c > 0xFF ? constants[c & 0xFF] : slots[c];
            if (table is VirtualSmallTableMarker && key is int) {
              slots[a] = key > table.length
                  ? null
                  : switch (key) {
                      1 => stack.virtualTriple1,
                      2 => stack.virtualTriple2,
                      3 => stack.virtualTriple3,
                      _ => null,
                    };
              break;
            }
            if (useInlineRegisterFastPaths && table is LuaTable) {
              Object? value;
              final normalizedKey =
                  key is double && LuaNumber.isInteger(key) ? key.toInt() : key;
              final array = table.arr;
              if (normalizedKey is int &&
                  array != null &&
                  normalizedKey >= 1 &&
                  normalizedKey <= array.length) {
                value = array[normalizedKey - 1];
              } else {
                value = table.map?[normalizedKey];
              }
              if (value != null || table.metatable == null) {
                slots[a] = value;
                break;
              }
            }
            stack.pc = pc;
            getTableRK(a + 1, b + 1, c);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 8: // SETTABUP
            if (useExtendedRegisterFastPaths) {
              final holder = upvalues[a];
              final table = holder?.stack != null
                  ? holder!.stack!.slots[holder.index!]
                  : holder?.value;
              if (table is LuaTable && table.metatable == null) {
                final key = b > 0xFF ? constants[b & 0xFF] : slots[b];
                final value = c > 0xFF ? constants[c & 0xFF] : slots[c];
                table.put(key, value);
                break;
              }
            }
            stack.pc = pc;
            Instructions.setTabUp(inst, this);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 9: // SETUPVAL
            if (useExtendedRegisterFastPaths) {
              final holder = upvalues[b]!;
              if (holder.stack != null) {
                holder.stack!.slots[holder.index!] = slots[a];
              } else {
                holder.value = slots[a];
              }
            } else {
              stack.pc = pc;
              Instructions.setUpval(inst, this);
              pc = stack.pc;
              slots = stack.slots;
            }
            break;
          case 10: // SETTABLE
            final table = slots[a];
            if (useInlineRegisterFastPaths &&
                table is LuaTable &&
                table.metatable == null) {
              final key = b > 0xFF ? constants[b & 0xFF] : slots[b];
              final value = c > 0xFF ? constants[c & 0xFF] : slots[c];
              table.put(key, value);
            } else {
              stack.pc = pc;
              setTableRK(a + 1, b, c);
              pc = stack.pc;
              slots = stack.slots;
            }
            break;
          case 11: // NEWTABLE
            if (useExtendedRegisterFastPaths) {
              slots[a] = LuaTable(FPB.fb2int(b), FPB.fb2int(c));
            } else {
              stack.pc = pc;
              Instructions.newTable(inst, this);
              pc = stack.pc;
              slots = stack.slots;
            }
            break;
          case >= 13 && <= 24: // binary arithmetic
            const operations = <ArithOp>[
              ArithOp.luaOpAdd,
              ArithOp.luaOpSub,
              ArithOp.luaOpMul,
              ArithOp.luaOpMod,
              ArithOp.luaOpPow,
              ArithOp.luaOpDiv,
              ArithOp.luaOpIdiv,
              ArithOp.luaOpBand,
              ArithOp.luaOpBor,
              ArithOp.luaOpBxor,
              ArithOp.luaOpShl,
              ArithOp.luaOpShr,
            ];
            final leftOperand = b;
            final rightOperand = c;
            final left = leftOperand > 0xFF
                ? constants[leftOperand & 0xFF]
                : slots[leftOperand];
            final right = rightOperand > 0xFF
                ? constants[rightOperand & 0xFF]
                : slots[rightOperand];
            Object? result;
            if (useInlineRegisterFastPaths && left is num && right is num) {
              final bothInts = left is int && right is int;
              result = switch (opcode) {
                13 =>
                  bothInts ? left + right : left.toDouble() + right.toDouble(),
                14 =>
                  bothInts ? left - right : left.toDouble() - right.toDouble(),
                15 =>
                  bothInts ? left * right : left.toDouble() * right.toDouble(),
                17 => math.pow(left.toDouble(), right.toDouble()),
                18 => left.toDouble() / right.toDouble(),
                _ => null,
              };
            }
            if (result == null) {
              stack.pc = pc;
              result =
                  Arithmetic.arith(left, right, operations[opcode - 13], this);
              pc = stack.pc;
              slots = stack.slots;
            }
            slots[a] = result;
            break;
          case 27: // NOT
            slots[a] = !LuaValue.toBoolean(slots[b]);
            break;
          case 30: // JMP
            final close = a;
            if (close != 0) {
              closeUpvalues(close);
            }
            pc += (inst >> 14) - Instruction.maxArg_sbx;
            break;
          case >= 31 && <= 33: // EQ, LT, LE
            final leftOperand = b;
            final rightOperand = c;
            final expected = a != 0;
            final left = leftOperand > 0xFF
                ? constants[leftOperand & 0xFF]
                : slots[leftOperand];
            final right = rightOperand > 0xFF
                ? constants[rightOperand & 0xFF]
                : slots[rightOperand];
            stack.pc = pc;
            final result = switch (opcode) {
              31 => Comparison.eq(left, right, this),
              32 => Comparison.lt(left, right, this),
              _ => Comparison.le(left, right, this),
            };
            pc = stack.pc;
            slots = stack.slots;
            if (result != expected) pc++;
            break;
          case 34: // TEST
            if (LuaValue.toBoolean(slots[a]) != (c != 0)) pc++;
            break;
          case 35: // TESTSET
            final source = b;
            if (LuaValue.toBoolean(slots[source]) == (c != 0)) {
              slots[a] = slots[source];
            } else {
              pc++;
            }
            break;
          case 36: // CALL
            final argumentField = b;
            final resultField = c;
            if (argumentField == 2 && slots[a + 1] is VirtualSmallTableMarker) {
              final target = slots[a];
              if (target is! Closure ||
                  target.proto == null ||
                  !_canConsumeVirtualTriple(target.proto!)) {
                slots[a + 1] = _materializeVirtualTriple(stack, a);
              }
            }
            if (useRegisterCalls &&
                argumentField > 0 &&
                (resultField > 0 || useOpenResultRegisterCalls)) {
              stack.pc = pc;
              final callResult = _callFixedRegisters(
                  stack, a, argumentField - 1, resultField - 1);
              if (callResult == 2) continue frameLoop;
              if (callResult == 1) {
                slots = stack.slots;
                break;
              }
            }
            if (argumentField == 2 && slots[a + 1] is VirtualSmallTableMarker) {
              slots[a + 1] = _materializeVirtualTriple(stack, a);
            }
            stack.pc = pc;
            Instructions.call(inst, this);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 37: // TAILCALL
            if (b == 2 && slots[a + 1] is VirtualSmallTableMarker) {
              slots[a + 1] = _materializeVirtualTriple(stack, a);
            }
            stack.pc = pc;
            Instructions.tailCall(inst, this);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 39: // FORLOOP
            final step = slots[a + 2] as num;
            final current = slots[a] as num;
            final num next = useInlineRegisterFastPaths
                ? (current is int && step is int
                    ? current + step
                    : current.toDouble() + step.toDouble())
                : Arithmetic.arith(current, step, ArithOp.luaOpAdd, this)
                    as num;
            slots[a] = next;
            final limit = slots[a + 1] as num;
            if ((step >= 0 && next <= limit) || (step < 0 && next >= limit)) {
              pc += (inst >> 14) - Instruction.maxArg_sbx;
              slots[a + 3] = next;
            }
            break;
          case 40: // FORPREP
            Object? initial = slots[a];
            Object? limit = slots[a + 1];
            Object? step = slots[a + 2];
            if (initial is String) initial = LuaValue.toFloat(initial);
            if (limit is String) limit = LuaValue.toFloat(limit);
            if (step is String) step = LuaValue.toFloat(step);
            if (useInlineRegisterFastPaths && initial is num && step is num) {
              slots[a] = initial is int && step is int
                  ? initial - step
                  : initial.toDouble() - step.toDouble();
            } else {
              stack.pc = pc;
              slots[a] =
                  Arithmetic.arith(initial, step, ArithOp.luaOpSub, this);
              pc = stack.pc;
              slots = stack.slots;
            }
            slots[a + 1] = limit;
            slots[a + 2] = step;
            pc += (inst >> 14) - Instruction.maxArg_sbx;
            break;
          case 42: // TFORLOOP
            if (slots[a + 1] != null) {
              slots[a] = slots[a + 1];
              pc += (inst >> 14) - Instruction.maxArg_sbx;
            }
            break;
          case 38: // RETURN
            stack.pc = pc;
            if (useIterativeRegisterCalls &&
                !identical(stack, root) &&
                useExtendedRegisterFastPaths &&
                b > 0) {
              // Complete a fixed-result Lua return as a frame transition. The
              // values never need to be staged above the callee's registers.
              final caller = stack.prev!;
              final destination = stack.registerReturnDestination;
              final wanted = stack.registerReturnCount;
              final available = b - 1;
              if (wanted < 0) {
                final callerRegisters = caller.closure!.proto!.maxStackSize;
                caller.setTopDirect(callerRegisters + available);
                final callerSlots = caller.slots;
                for (int i = 0; i < available; i++) {
                  callerSlots[callerRegisters + i] = slots[a + i];
                }
                caller.push(destination + 1);
              } else {
                final callerSlots = caller.slots;
                for (int i = 0; i < wanted; i++) {
                  callerSlots[destination + i] =
                      i < available ? slots[a + i] : null;
                }
              }
              _stack = caller;
              stack.prev = null;
              _releaseRegisterCallFrame(stack);
              continue frameLoop;
            }
            if (useExtendedRegisterFastPaths && b > 0) {
              final count = b - 1;
              final registerCount = proto.maxStackSize;
              stack.setTopDirect(registerCount + count);
              slots = stack.slots;
              for (int i = 0; i < count; i++) {
                slots[registerCount + i] = slots[a + i];
              }
            } else {
              Instructions.return_(inst, this);
            }
            if (useIterativeRegisterCalls && !identical(stack, root)) {
              _finishRegisterLuaCall(stack);
              continue frameLoop;
            }
            return;
          case 41: // TFORCALL
            if (useDirectIPairsIteration) {
              final iterator = slots[a];
              final table = slots[a + 1];
              final control = slots[a + 2];
              if (iterator is Closure &&
                  identical(iterator.dartFunc, BasicLib.iPairsAux) &&
                  table is LuaTable &&
                  table.metatable == null &&
                  control is int) {
                final next = control + 1;
                final value = table.get(next);
                slots[a + 3] = value == null ? null : next;
                slots[a + 4] = value;
                break;
              }
            }
            if (useExtendedRegisterFastPaths) {
              stack.pc = pc;
              final callResult = _callFixedRegisters(stack, a, 2, c, a + 3);
              if (callResult == 2) continue frameLoop;
              if (callResult == 1) {
                slots = stack.slots;
                break;
              }
            }
            stack.pc = pc;
            Instructions.tForCall(inst, this);
            pc = stack.pc;
            slots = stack.slots;
            break;
          case 43: // SETLIST
            if (useExtendedRegisterFastPaths && b > 0) {
              final table = slots[a] as LuaTable;
              final block = c > 0 ? c - 1 : code[pc++] >> 6;
              var index = block * Instructions.lfields_per_flush;
              for (int i = 1; i <= b; i++) {
                table.put(++index, slots[a + i]);
              }
            } else {
              stack.pc = pc;
              Instructions.setList(inst, this);
              pc = stack.pc;
              slots = stack.slots;
            }
            break;
          case 46: // EXTRAARG
            break;
          default:
            stack.pc = pc;
            opCodes[opcode].action!(inst, this);
            pc = stack.pc;
            slots = stack.slots;
        }
      }
    }
  }

  /// Asynchronously call a function.
  /// This handles both sync and async Dart functions as well as Lua closures.
  @override
  Future<void> callAsync(int nArgs, int nResults) async {
    Object? val = _stack!.get(-(nArgs + 1));
    Object? f = val is Closure ? val : null;

    if (f == null) {
      Object? mf = _getMetafield(val, "__call");
      if (mf != null && mf is Closure) {
        _stack!.push(f);
        insert(-(nArgs + 2));
        nArgs += 1;
        f = mf;
      }
    }

    if (f != null) {
      Closure c = f as Closure;
      if (c.proto != null) {
        _callLuaClosure(nArgs, nResults, c);
      } else if (c.isAsync) {
        await _callDartClosureAsync(nArgs, nResults, c);
      } else {
        _callDartClosure(nArgs, nResults, c);
      }
    } else {
      throw Exception(
          _stack!.formatError("attempt to call a non-function value"));
    }
  }

  /// Asynchronously call an async Dart closure.
  Future<void> _callDartClosureAsync(int nArgs, int nResults, Closure c) async {
    // create new lua stack
    LuaStack newStack = _newStack();
    newStack.state = this;
    newStack.closure = c;

    // pass args, pop func
    if (nArgs > 0) {
      newStack.pushN(_stack!.popN(nArgs), nArgs);
    }
    _stack!.pop();

    // run closure
    _pushLuaStack(newStack);
    int r = await c.dartFuncAsync!.call(this);
    _popLuaStack();

    // return results
    if (nResults != 0) {
      List<Object?> results = newStack.popN(r);
      _stack!.pushN(results, nResults);
    }
  }

  /// Asynchronously call a function in protected mode.
  @override
  Future<ThreadStatus> pCallAsync(int nArgs, int nResults, int msgh) async {
    LuaStack? caller = _stack;
    try {
      await callAsync(nArgs, nResults);
      return ThreadStatus.luaOk;
    } catch (e) {
      if (msgh != 0) {
        rethrow;
      }
      while (_stack != caller) {
        _popLuaStack();
      }
      if (e is LuaError) {
        _stack!.push(e.value);
      } else {
        _stack!.push("$e");
      }
      return ThreadStatus.luaErrRun;
    }
  }

  @override
  ThreadStatus load(Uint8List chunk, String chunkName, String? mode) {
    Prototype proto = BinaryChunk.isBinaryChunk(chunk)
        ? BinaryChunk.unDump(chunk)
        : Compiler.compile(utf8.decode(chunk), chunkName);
    Closure closure = Closure(proto);
    _stack!.push(closure);
    if (proto.upvalues.length > 0) {
      Object? env = registry!.get(luaRidxGlobals);
      closure.upvals[0] = UpvalueHolder.value(env); // todo
    }
    return ThreadStatus.luaOk;
  }

  @override
  bool isDartFunction(int idx) {
    Object? val = _stack!.get(idx);
    return val is Closure && val.dartFunc != null;
  }

  @override
  void pushDartFunction(f) {
    _stack!.push(Closure.DartFunc(f, 0));
  }

  @override
  toDartFunction(int idx) {
    Object? val = _stack!.get(idx);
    return val is Closure ? val.dartFunc : null;
  }

  @override
  LuaType getGlobal(String name) {
    Object? t = registry!.get(luaRidxGlobals);
    return _getTable(t, name, false);
  }

  @override
  void pushGlobalTable() {
    _stack!.push(registry!.get(luaRidxGlobals));
  }

  @override
  void pushDartClosure(DartFunction? f, int n) {
    Closure closure = Closure.DartFunc(f, n);
    for (int i = n; i > 0; i--) {
      Object? val = _stack!.pop();
      closure.upvals[i - 1] = UpvalueHolder.value(val);
    }
    _stack!.push(closure);
  }

  @override
  void pushDartFunctionAsync(DartFunctionAsync f) {
    _stack!.push(Closure.DartFuncAsync(f, 0));
  }

  @override
  void pushDartClosureAsync(DartFunctionAsync f, int n) {
    Closure closure = Closure.DartFuncAsync(f, n);
    for (int i = n; i > 0; i--) {
      Object? val = _stack!.pop();
      closure.upvals[i - 1] = UpvalueHolder.value(val);
    }
    _stack!.push(closure);
  }

  @override
  void register(String name, f) {
    pushDartFunction(f);
    setGlobal(name);
  }

  @override
  void registerAsync(String name, DartFunctionAsync f) {
    pushDartFunctionAsync(f);
    setGlobal(name);
  }

  @override
  void setGlobal(String name) {
    Object? t = registry!.get(luaRidxGlobals);
    Object? v = _stack!.pop();
    _setTable(t, name, v, false);
  }

  @override
  bool getMetatable(int idx) {
    Object? val = _stack!.get(idx);
    Object? mt = _getMetatable(val);
    if (mt != null) {
      _stack!.push(mt);
      return true;
    } else {
      return false;
    }
  }

  @override
  bool rawEqual(int idx1, int idx2) {
    if (!_stack!.isValid(idx1) || !_stack!.isValid(idx2)) {
      return false;
    }

    Object? a = _stack!.get(idx1);
    Object? b = _stack!.get(idx2);
    return Comparison.eq(a, b, null);
  }

  @override
  LuaType rawGet(int idx) {
    Object? t = _stack!.get(idx);
    Object? k = _stack!.pop();
    return _getTable(t, k, true);
  }

  @override
  LuaType rawGetI(int idx, int i) {
    Object? t = _stack!.get(idx);
    return _getTable(t, i, true);
  }

  @override
  int rawLen(int idx) {
    Object? val = _stack!.get(idx);
    if (val is String) {
      return val.length;
    } else if (val is LuaTable) {
      return val.length();
    } else {
      return 0;
    }
  }

  @override
  void rawSet(int idx) {
    Object? t = _stack!.get(idx);
    Object? v = _stack!.pop();
    Object? k = _stack!.pop();
    _setTable(t, k, v, true);
  }

  @override
  void rawSetI(int idx, int i) {
    Object? t = _stack!.get(idx);
    Object? v = _stack!.pop();
    _setTable(t, i, v, true);
  }

  @override
  void setMetatable(int idx) {
    Object? val = _stack!.get(idx);
    Object? mtVal = _stack!.pop();

    if (mtVal == null) {
      _setMetatable(val, null);
    } else if (mtVal is LuaTable) {
      _setMetatable(val, mtVal);
    } else {
      // Fix #33: Include line number in error message
      throw Exception(_stack!.formatError("table expected for metatable"));
    }
  }

  @override
  bool next(int idx) {
    Object? val = _stack!.get(idx);
    if (val is LuaTable) {
      LuaTable t = val;
      Object? key = _stack!.pop();
      Object? nextKey = t.nextKey(key);
      if (nextKey != null) {
        _stack!.push(nextKey);
        _stack!.push(t.get(nextKey));
        return true;
      }
      return false;
    }
    // Fix #33: Include line number in error message
    throw Exception(_stack!.formatError("table expected for iteration"));
  }

  @override
  int error() {
    Object? err = _stack!.pop();
    if (err is String) {
      // String errors get line info appended (Fix #33).
      throw LuaError(_stack!.formatError(err));
    }
    // Non-string errors (tables, numbers, etc.) are preserved as-is.
    throw LuaError(err);
  }

  /// Fix #33: Public method to format error messages with line numbers
  /// This is used by external classes like Comparison and Arithmetic
  String formatError(String message) {
    return _stack!.formatError(message);
  }

  @override
  ThreadStatus pCall(int nArgs, int nResults, int msgh) {
    LuaStack? caller = _stack;
    try {
      call(nArgs, nResults);
      return ThreadStatus.luaOk;
    } catch (e) {
      if (msgh != 0) {
        throw e;
      }
      while (_stack != caller) {
        _popLuaStack();
      }
      // Preserve raw Lua error values (tables, numbers, etc.)
      if (e is LuaError) {
        _stack!.push(e.value);
      } else {
        _stack!.push("$e");
      }
      return ThreadStatus.luaErrRun;
    }
  }

  //**************************************************
  //******************* LuaAuxLib ********************
  //**************************************************
  @override
  void argCheck(bool? cond, int arg, String extraMsg) {
    if (!cond!) {
      argError(arg, extraMsg);
    }
  }

  @override
  int argError(int arg, String extraMsg) {
    return error2("bad argument #%d (%s)", [arg, extraMsg]); // todo
  }

  @override
  bool callMeta(int obj, String e) {
    obj = absIndex(obj);
    if (getMetafield(obj, e) == LuaType.luaNil) {
      /* no metafield? */
      return false;
    }

    pushValue(obj);
    call(1, 1);
    return true;
  }

  @override
  void checkAny(int arg) {
    if (type(arg) == LuaType.luaNone) {
      argError(arg, "value expected");
    }
  }

  @override
  int? checkInteger(int arg) {
    int? i = toIntegerX(arg);
    if (i == null) {
      intError(arg);
    }
    return i;
  }

  void intError(int arg) {
    if (isNumber(arg)) {
      argError(arg, "number has no integer representation");
    } else {
      tagError(arg, LuaType.luaNumber);
    }
  }

  void tagError(int arg, LuaType tag) {
    typeError(arg, typeName(tag));
  }

  void typeError(int arg, String tname) {
    String? typeArg; /* name for the type of the actual argument */
    if (getMetafield(arg, "__name") == LuaType.luaString) {
      typeArg = toStr(-1); /* use the given type name */
    } else if (type(arg) == LuaType.luaLightUserdata) {
      typeArg = "light userdata"; /* special name for messages */
    } else {
      typeArg = typeName2(arg); /* standard name */
    }
    String msg = tname + " expected, got " + typeArg!;
    pushString(msg);
    argError(arg, msg);
  }

  @override
  double? checkNumber(int arg) {
    double? f = toNumberX(arg);
    if (f == null) {
      tagError(arg, LuaType.luaNumber);
    }
    return f;
  }

  @override
  void checkStack2(int sz, String msg) {
    if (!checkStack(sz)) {
      if (msg != "") {
        error2("stack overflow (%s)", [msg]);
      } else {
        error2("stack overflow");
      }
    }
  }

  @override
  String? checkString(int arg) {
    String? s = toStr(arg);
    if (s == null) {
      tagError(arg, LuaType.luaString);
    }
    return s;
  }

  @override
  void checkType(int arg, LuaType t) {
    if (type(arg) != t) {
      tagError(arg, t);
    }
  }

  @override
  bool doFile(String filename) {
    return loadFile(filename) == ThreadStatus.luaOk &&
        pCall(0, luaMultret, 0) == ThreadStatus.luaOk;
  }

  @override
  bool doString(String str) {
    return loadString(str) == ThreadStatus.luaOk &&
        pCall(0, luaMultret, 0) == ThreadStatus.luaOk;
  }

  @override
  Future<bool> doFileAsync(String filename) async {
    try {
      if (loadFile(filename) != ThreadStatus.luaOk) {
        return false;
      }
      return await pCallAsync(0, luaMultret, 0) == ThreadStatus.luaOk;
    } catch (e) {
      _stack!.push("$e");
      return false;
    }
  }

  @override
  Future<bool> doStringAsync(String str) async {
    try {
      if (loadString(str) != ThreadStatus.luaOk) {
        return false;
      }
      return await pCallAsync(0, luaMultret, 0) == ThreadStatus.luaOk;
    } catch (e) {
      _stack!.push("$e");
      return false;
    }
  }

  @override
  int error2(String fmt, [List<Object?>? a]) {
    pushFString(fmt, a);
    return error();
  }

  @override
  LuaType getMetafield(int obj, String e) {
    if (!getMetatable(obj)) {
      /* no metatable? */
      return LuaType.luaNil;
    }

    pushString(e);
    LuaType tt = rawGet(-2);
    if (tt == LuaType.luaNil) {
      /* is metafield nil? */
      pop(2); /* remove metatable and metafield */
    } else {
      remove(-2); /* remove only metatable */
    }
    return tt; /* return metafield type */
  }

  @override
  LuaType getMetatableAux(String tname) {
    return getField(luaRegistryIndex, tname);
  }

  @override
  bool getSubTable(int idx, String fname) {
    if (getField(idx, fname) == LuaType.luaTable) {
      return true; /* table already there */
    }
    pop(1); /* remove previous result */
    idx = _stack!.absIndex(idx);
    newTable();
    pushValue(-1); /* copy to be left at top */
    setField(idx, fname); /* assign new table to field */
    return false; /* false, because did not find table there */
  }

  @override
  int? len2(int idx) {
    len(idx);
    int? i = toIntegerX(-1);
    if (i == null) {
      error2("object length is not an integer");
    }
    pop(1);
    return i;
  }

  @override
  ThreadStatus loadFile(String? filename) {
    return loadFileX(filename, "bt");
  }

  @override
  ThreadStatus loadFileX(String? filename, String? mode) {
    if (!PlatformServices.instance.supportsFileSystem) {
      return ThreadStatus.luaErrFile;
    }

    try {
      final bytes = PlatformServices.instance.readFileAsBytes(filename!);
      if (bytes == null) {
        return ThreadStatus.luaErrFile;
      }
      return load(bytes, "@" + filename, mode);
    } catch (e, s) {
      // ignore: avoid_print
      print(e);
      // ignore: avoid_print
      print(s);
      return ThreadStatus.luaErrFile;
    }
  }

  @override
  ThreadStatus loadString(String s) {
    return load(Uint8List.fromList(utf8.encode(s)), s, "bt");
  }

  @override
  void newLib(Map l) {
    newLibTable(l);
    setFuncs(l as Map<String, int Function(LuaState)?>, 0);
  }

  @override
  void newLibTable(Map l) {
    createTable(0, l.length);
  }

  @override
  void openLibs() {
    Map<String, DartFunction> libs = <String, DartFunction>{
      "_G": BasicLib.openBaseLib,
      "package": PackageLib.openPackageLib,
      "table": TableLib.openTableLib,
      "string": StringLib.openStringLib,
      "math": MathLib.openMathLib,
      "os": OSLib.openOSLib,
      "coroutine": CoroutineLib.openCoroutineLib,
    };

    libs.forEach((name, fun) {
      requireF(name, fun, true);
      pop(1);
    });
  }

  @override
  int? optInteger(int arg, int? dft) {
    return isNoneOrNil(arg) ? dft : checkInteger(arg);
  }

  @override
  double? optNumber(int arg, double d) {
    return isNoneOrNil(arg) ? d : checkNumber(arg);
  }

  @override
  String? optString(int arg, String d) {
    return isNoneOrNil(arg) ? d : checkString(arg);
  }

  @override
  void pushFString(String fmt, [List<Object?>? a]) {
    String? str = a == null ? fmt : sprintf(fmt, a);
    pushString(str);
  }

  @override
  void requireF(String modname, openf, bool glb) {
    getSubTable(luaRegistryIndex, "_LOADED");
    getField(-1, modname); /* LOADED[modname] */
    if (!toBoolean(-1)) {
      /* package not already loaded? */
      pop(1); /* remove field */
      pushDartFunction(openf);
      pushString(modname); /* argument to open function */
      call(1, 1); /* call 'openf' to open module */
      pushValue(-1); /* make copy of module (call result) */
      setField(-3, modname); /* _LOADED[modname] = module */
    }
    remove(-2); /* remove _LOADED table */
    if (glb) {
      pushValue(-1); /* copy of module */
      setGlobal(modname); /* _G[modname] = module */
    }
  }

  @override
  void setMetatableAux(String tname) {
    getMetatableAux(tname);
    setMetatable(-2);
  }

  @override
  void setFuncs(Map<String, DartFunction?> l, int nup) {
    checkStack2(nup, "too many upvalues");
    l.forEach((name, fun) {
      /* fill the table with given functions */
      for (int i = 0; i < nup; i++) {
        /* copy upvalues to the top */
        pushValue(-nup);
      }
      // r[-(nup+2)][name]=fun
      pushDartClosure(fun, nup); /* closure with those upvalues */
      setField(-(nup + 2), name);
    });
    pop(nup); /* remove upvalues */
  }

  @override
  bool stringToNumber(String s) {
    int? i = LuaNumber.parseInteger(s);
    if (i != null) {
      pushInteger(i);
      return true;
    }
    double? f = LuaNumber.parseFloat(s);
    if (f != null) {
      pushNumber(f);
      return true;
    }
    return false;
  }

  @override
  Object? toPointer(int idx) {
    return _stack!.get(idx); // todo
  }

  @override
  String? toString2(int idx) {
    if (callMeta(idx, "__tostring")) {
      /* metafield? */
      if (!isString(-1)) {
        error2("'__tostring' must return a string");
      }
    } else {
      switch (type(idx)) {
        case LuaType.luaNumber:
          if (isInteger(idx)) {
            pushString("${toInteger(idx)}"); // todo
          } else {
            pushString(sprintf("%g", [toNumber(idx)]));
          }
          break;
        case LuaType.luaString:
          pushValue(idx);
          break;
        case LuaType.luaBoolean:
          pushString(toBoolean(idx) ? "true" : "false");
          break;
        case LuaType.luaNil:
          pushString("nil");
          break;
        default:
          LuaType tt = getMetafield(idx, "__name");
          /* try name */
          String? kind =
              tt == LuaType.luaString ? checkString(-1) : typeName2(idx);
          pushString("$kind: ${toPointer(idx).hashCode}");
          if (tt != LuaType.luaNil) {
            remove(-2); /* remove '__name' */
          }
          break;
      }
    }
    return checkString(-1);
  }

  @override
  String typeName2(int idx) {
    return typeName(type(idx));
  }

  @override
  bool newMetatable(String tname) {
    if (getMetatableAux(tname) != LuaType.luaNil) {
      /* name already in use? */
      return false; /* leave previous value on top, but return false */
    }

    pop(1);
    createTable(0, 2); /* create metatable */
    pushString(tname);
    setField(-2, "__name"); /* metatable.__name = tname */
    pushValue(-1);
    setField(luaRegistryIndex, tname); /* registry.name = metatable */
    return true;
  }

  int ref(int t) {
    int _ref;
    if (isNil(-1)) {
      pop(1); /* remove from stack */
      return -1; /* 'nil' has a unique fixed reference */
    }
    t = absIndex(t);
    rawGetI(t, 0); /* get first free element */
    _ref = toInteger(-1); /* ref = t[freelist] */
    pop(1); /* remove it from stack */
    if (_ref != 0) {
      /* any free element? */
      rawGetI(t, _ref); /* remove it from list */
      rawSetI(t, 0); /* (t[freelist] = t[ref]) */
    } else
      /* no free elements */
      _ref = rawLen(t) + 1;
    /* get a new reference */

    rawSetI(t, _ref);
    return _ref;
  }

  void unRef(int t, int ref) {
    if (ref >= 0) {
      t = absIndex(t);
      rawGetI(t, 0);
      rawSetI(t, ref); /* t[ref] = t[freelist] */
      pushInteger(ref);
      rawSetI(t, 0); /* t[freelist] = ref */
    }
  }

  //**************************************************
  //******************** LuaVM ***********************
  //**************************************************
  @override
  void addPC(int n) {
    _stack!.pc += n;
  }

  @override
  int fetch() {
    return _stack!.closure!.proto!.code[_stack!.pc++];
  }

  @override
  void getConst(int idx) {
    _stack!.push(_stack!.closure!.proto!.constants[idx]);
  }

  @override
  int getPC() {
    return _stack!.pc;
  }

  @override
  void getRK(int rk) {
    if (rk > 0xFF) {
      // constant
      getConst(rk & 0xFF);
    } else {
      // register
      pushValue(rk + 1);
    }
  }

  @override
  void binaryArithRK(int dest, int b, int c, ArithOp op) {
    final stack = _stack!;
    final constants = stack.closure!.proto!.constants;
    final left = b > 0xFF ? constants[b & 0xFF] : stack.slots[b];
    final right = c > 0xFF ? constants[c & 0xFF] : stack.slots[c];
    final result = Arithmetic.arith(left, right, op, this);
    if (result == null) {
      throw Exception(stack
          .formatError('attempt to perform arithmetic on a non-number value'));
    }
    stack.slots[dest - 1] = result;
  }

  @override
  void setListRegisters(int table, int count, int startIndex) {
    final slots = _stack!.slots;
    final target = slots[table - 1] as LuaTable;
    for (int i = 1; i <= count; i++) {
      target.put(startIndex + i, slots[table + i - 1]);
    }
  }

  @override
  bool compareRK(int left, int right, CmpOp op) {
    final stack = _stack!;
    final constants = stack.closure!.proto!.constants;
    final a = left > 0xFF ? constants[left & 0xFF] : stack.slots[left];
    final b = right > 0xFF ? constants[right & 0xFF] : stack.slots[right];
    switch (op) {
      case CmpOp.luaOpEq:
        return Comparison.eq(a, b, this);
      case CmpOp.luaOpLt:
        return Comparison.lt(a, b, this);
      case CmpOp.luaOpLe:
        return Comparison.le(a, b, this);
    }
  }

  @override
  void setTableRK(int table, int key, int value) {
    final stack = _stack!;
    final slots = stack.slots;
    final constants = stack.closure!.proto!.constants;
    final target = slots[table - 1];
    final k = key > 0xFF ? constants[key & 0xFF] : slots[key];
    final v = value > 0xFF ? constants[value & 0xFF] : slots[value];

    if (target is LuaTable &&
        (target.get(k) != null || !target.hasMetafield('__newindex'))) {
      target.put(k, v);
      return;
    }
    _setTable(target, k, v, false);
  }

  @override
  void getTableRK(int dest, int table, int key) {
    final stack = _stack!;
    final slots = stack.slots;
    final t = slots[table - 1];
    final constants = stack.closure!.proto!.constants;
    final k = key > 0xFF ? constants[key & 0xFF] : slots[key];

    // Plain tables are by far the common case. Missing values can also be
    // assigned directly when there is no __index metamethod.
    if (t is LuaTable) {
      final value = t.get(k);
      if (value != null || !t.hasMetafield('__index')) {
        slots[dest - 1] = value;
        return;
      }
    }

    // Preserve all generic indexing and metamethod behavior off the fast path.
    _getTable(t, k, false);
    slots[dest - 1] = stack.pop();
  }

  @override
  void loadProto(int idx) {
    Prototype proto = _stack!.closure!.proto!.protos[idx]!;
    Closure closure = Closure(proto);
    _stack!.push(closure);

    for (int i = 0; i < proto.upvalues.length; i++) {
      Upvalue uvInfo = proto.upvalues[i]!;
      int? uvIdx = uvInfo.idx;
      if (uvInfo.instack == 1) {
        if (_stack!.openuvs == null) {
          _stack!.openuvs = Map<int?, UpvalueHolder?>();
        }
        if (_stack!.openuvs!.containsKey(uvIdx)) {
          closure.upvals[i] = _stack!.openuvs![uvIdx];
        } else {
          closure.upvals[i] = UpvalueHolder(_stack, uvIdx);
          _stack!.openuvs![uvIdx] = closure.upvals[i];
        }
      } else {
        closure.upvals[i] = _stack!.closure!.upvals[uvIdx!];
      }
    }
  }

  @override
  void loadVararg(int n) {
    List<Object?>? varargs =
        _stack!.varargs != null ? _stack!.varargs : const <Object>[];
    if (n < 0) {
      n = varargs!.length;
    }

    //stack.check(n)
    _stack!.pushN(varargs, n);
  }

  @override
  int registerCount() {
    return _stack!.closure!.proto!.maxStackSize;
  }

  @override
  void closeUpvalues(int a) {
    if (_stack!.openuvs != null) {
      _stack!.openuvs!.removeWhere((k, v) {
        if (v!.index! >= a - 1) {
          v.migrate();
          return true;
        } else
          return false;
      });
    }
  }

//**************************************************
//************** LuaCoroutineLib *******************
//**************************************************

  @override
  LuaState? toThread(int idx) {
    Object? val = _stack!.get(idx);
    return val is LuaState ? val : null;
  }

  @override
  void pushThread(LuaState L) {
    _stack!.push(L);
  }

  @override
  void xmove(LuaState from, int n) {
    if (n <= 0) return;
    LuaStateImpl fromImpl = from as LuaStateImpl;
    List<Object?> vals = fromImpl._stack!.popN(n);
    _stack!.pushN(vals, n);
  }

  @override
  Object? popObject() {
    return _stack!.pop();
  }

  @override
  LuaState newThread() {
    // Create new thread that shares the registry (global environment)
    // Note: Does NOT push to stack - caller is responsible for that
    LuaStateImpl newState = LuaStateImpl.newThread(registry!);
    return newState;
  }

  @override
  String debugThread() {
    return 'Thread[id=$id, status=$status]';
  }

  @override
  void clearThreadWeakRef() {
    // Clear weak references to dead threads in registry
    // This is a no-op for now since Dart handles GC automatically
  }

  @override
  void setStatus(ThreadStatus newStatus) {
    status = newStatus;
  }

  @override
  ThreadStatus getStatus() {
    return status;
  }

  @override
  void resume(int nArgs) {
    // Resume execution from a yield point.
    if (_stack!.closure == null) {
      throw Exception('No closure to resume');
    }

    // The resume arguments (pushed by xmove in _coResume) sit on top of
    // the current frame's stack.  They must be placed into the registers
    // where the interrupted CALL instruction expects its results — exactly
    // what popResults would have done had the CALL completed normally.
    if (_stack!.closure!.proto != null && _stack!.pc > 0) {
      final prevInstr = _stack!.closure!.proto!.code[_stack!.pc - 1];
      final opCode = Instruction.getOpCode(prevInstr);
      if (opCode.name == "CALL" || opCode.name == "TAILCALL") {
        final a = Instruction.getA(prevInstr) + 1;
        final c = Instruction.getC(prevInstr);
        if (c == 1) {
          // No results expected — discard the resume args.
          for (var i = 0; i < nArgs; i++) {
            pop(1);
          }
        } else if (c > 1) {
          // Exactly c-1 results expected.
          final nExpected = c - 1;
          final vals = _stack!.popN(nArgs);
          _stack!.pushN(vals, nExpected);
          for (int j = a + nExpected - 1; j >= a; j--) {
            replace(j);
          }
        } else {
          // Variable results (c == 0) — leave on stack.
          checkStack(1);
          pushInteger(a);
        }
      }
    }

    // Continue the innermost frame that was interrupted by yield.
    _runLuaClosure();

    // Unwind nested Lua function calls that were interrupted by yield.
    // Stop when the parent frame has no Lua proto (i.e. it's the root).
    while (_stack!.prev != null && _stack!.prev!.closure?.proto != null) {
      final innerStack = _stack!;
      final nRegs = innerStack.closure?.proto?.maxStackSize ?? 0;
      final results = innerStack.popN(innerStack.top() - nRegs);

      _popLuaStack();

      // The outer frame's PC is past the CALL instruction that invoked
      // the inner function (fetch() advanced it before executing CALL).
      final callInstr = _stack!.closure!.proto!.code[_stack!.pc - 1];
      final a = Instruction.getA(callInstr) + 1;
      final c = Instruction.getC(callInstr);

      // Place results into the correct registers, mirroring popResults.
      if (c == 1) {
        // No results expected.
      } else if (c > 1) {
        final nResults = c - 1;
        _stack!.pushN(results, nResults);
        for (int j = a + nResults - 1; j >= a; j--) {
          replace(j);
        }
      } else {
        // c == 0: variable results — leave on stack.
        _stack!.pushN(results, results.length);
        checkStack(1);
        pushInteger(a);
      }

      // Continue the outer frame's bytecode.
      _runLuaClosure();
    }

    // The current frame is now the coroutine body function, sitting
    // above the root frame. Pop it and transfer only the return values
    // so that _coResume's co.getTop() sees results, not locals.
    if (_stack!.prev != null && _stack!.closure?.proto != null) {
      final bodyStack = _stack!;
      final nRegs = bodyStack.closure!.proto!.maxStackSize;
      final results = bodyStack.popN(bodyStack.top() - nRegs);
      _popLuaStack();
      _stack!.pushN(results, results.length);
    }
  }

  @override
  int runningId() {
    return id;
  }

  @override
  int getCurrentNResults() {
    // Get the expected number of results from the calling context
    if (_stack!.prev != null && _stack!.prev!.closure != null) {
      return _stack!.prev!.closure!.nResults;
    }
    return 0;
  }

  @override
  void resetTopClosureNResults(int nResults) {
    if (_stack!.closure != null) {
      _stack!.closure!.nResults = nResults;
    }
  }

  @override
  String traceStack() {
    StringBuffer sb = StringBuffer();
    sb.writeln('Stack trace:');
    LuaStack? stack = _stack;
    int level = 0;
    while (stack != null) {
      if (stack.closure != null) {
        final rawSource = stack.closure!.proto?.source;
        // Apply luaO_chunkid-style truncation so frame labels don't embed
        // the entire script source (e.g. for chunks loaded via loadString).
        final funcName =
            rawSource == null ? '<dart function>' : LuaStack.chunkid(rawSource);
        int line = stack.pc > 0 && stack.closure!.proto != null
            ? (stack.closure!.proto!.lineInfo.isNotEmpty
                ? stack.closure!.proto!.lineInfo[stack.pc - 1]
                : 0)
            : 0;
        sb.writeln('  [$level] $funcName:$line');
      }
      stack = stack.prev;
      level++;
    }
    return sb.toString();
  }

  @override
  void popStackFrame() {
    // Pop the top stack frame (used after catching yield exception)
    if (_stack != null && _stack!.prev != null) {
      _popLuaStack();
    }
  }

//**************************************************
//****************** LuaDebug **********************
//**************************************************

  @override
  void setHook(HookContext context) {
    hookList.add(context);
  }

//**************************************************
//**************************************************
//**************************************************
}
