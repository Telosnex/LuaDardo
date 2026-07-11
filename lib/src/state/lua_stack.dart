import '../api/lua_state.dart';
import 'closure.dart';
import 'lua_state_impl.dart';
import 'lua_table.dart';
import 'upvalue_holder.dart';

class LuaStack {
  static const int _defaultCapacity = 40;
  static const int _minCapacity = 20;

  /// Virtual stack — either a fixed-capacity array with an explicit `_top`
  /// pointer, or a growable list (legacy mode, for benchmark baseline).
  List<Object?> slots;

  /// Number of values on the stack.  Only meaningful in fixed-capacity mode;
  /// in growable mode [slots.length] is used instead.
  int _top;

  /// Whether this stack uses the optimised fixed-capacity representation.
  final bool _fixed;

  /// call info
  late LuaStateImpl state;
  Closure? closure;
  List<Object?>? varargs;
  Map<int?, UpvalueHolder?>? openuvs;

  /// Program Counter
  int pc = 0;

  /// linked list
  LuaStack? prev;

  // Direct-register continuation for an iteratively executed Lua call.
  int registerReturnDestination = -1;
  int registerReturnCount = 0;

  /// Creates a fixed-capacity stack (optimised).
  ///
  /// [capacity] is the initial slot count; the array will grow automatically
  /// if more space is needed, but starting at the right size avoids resizes
  /// on the hot path.
  LuaStack([int capacity = _defaultCapacity])
      : _fixed = true,
        slots = List<Object?>.filled(
            capacity < _minCapacity ? _minCapacity : capacity, null),
        _top = 0;

  /// Creates a growable-list stack (original behaviour).
  ///
  /// Used only as a benchmark baseline via [LuaStateImpl.useFixedStack].
  LuaStack.growable()
      : _fixed = false,
        slots = [],
        _top = 0;

  int top() => _fixed ? _top : slots.length;

  /// Prepares a completed fixed stack for use as a fresh call frame.
  /// Slots are overwritten by argument setup and [setTopDirect], avoiding an
  /// otherwise redundant clearing pass while the frame is pooled.
  void prepareForCallReuse() {
    _top = 0;
    closure = null;
    varargs = null;
    openuvs = null;
    pc = 0;
    prev = null;
    registerReturnDestination = -1;
    registerReturnCount = 0;
  }

  /// Reserves an argument range whose slots will immediately be overwritten.
  void reserveCallArguments(int count) {
    if (_fixed) {
      if (count > slots.length) _grow(count);
      _top = count;
    } else {
      setTopDirect(count);
    }
  }

  // ── Core push / pop ──────────────────────────────────────────────────

  void push(Object? val) {
    if (_fixed) {
      if (_top >= 10000) throw StackOverflowError();
      if (_top >= slots.length) _grow(_top + 1);
      slots[_top++] = val;
    } else {
      if (slots.length > 10000) throw StackOverflowError();
      slots.add(val);
    }
  }

  Object? pop() {
    if (_fixed) {
      final val = slots[--_top];
      slots[_top] = null; // allow GC
      return val;
    } else {
      return slots.removeAt(slots.length - 1);
    }
  }

  void pushN(List<Object?>? vals, int n) {
    int nVals = vals == null ? 0 : vals.length;
    if (n < 0) n = nVals;
    if (_fixed) {
      _ensureCapacity(_top + n);
      for (int i = 0; i < n; i++) {
        slots[_top++] = i < nVals ? vals![i] : null;
      }
    } else {
      for (int i = 0; i < n; i++) {
        push(i < nVals ? vals![i] : null);
      }
    }
  }

  /// Removes a function and its arguments from this stack and copies the
  /// parameters directly into [callee]. This avoids temporary `popN` and
  /// `sublist` allocations for every Lua-to-Lua call.
  void transferCallTo(
    LuaStack callee,
    int nArgs,
    int nParams,
    bool isVararg,
  ) {
    if (!_fixed || !callee._fixed) {
      final funcAndArgs = popN(nArgs + 1);
      callee.pushN(funcAndArgs.sublist(1), nParams);
      if (nArgs > nParams && isVararg) {
        callee.varargs = funcAndArgs.sublist(nParams + 1);
      }
      return;
    }

    final argsStart = _top - nArgs;
    for (int i = 0; i < nParams; i++) {
      callee.push(i < nArgs ? slots[argsStart + i] : null);
    }
    if (nArgs > nParams && isVararg) {
      callee.varargs = List<Object?>.generate(
        nArgs - nParams,
        (i) => slots[argsStart + nParams + i],
        growable: false,
      );
    }

    final functionIndex = argsStart - 1;
    for (int i = functionIndex; i < _top; i++) {
      slots[i] = null;
    }
    _top = functionIndex;
  }

  /// Copies return values above [registerCount] directly to [caller].
  void transferResultsTo(
    LuaStack caller,
    int registerCount,
    int nResults,
  ) {
    if (!_fixed || !caller._fixed) {
      final results = popN(top() - registerCount);
      caller.pushN(results, nResults);
      return;
    }

    final available = _top - registerCount;
    final count = nResults < 0 ? available : nResults;
    for (int i = 0; i < count; i++) {
      caller.push(i < available ? slots[registerCount + i] : null);
    }
  }

  List<Object?> popN(int n) {
    if (_fixed) {
      // Single allocation, filled back-to-front — no reversal needed.
      final vals = List<Object?>.filled(n, null);
      for (int i = n - 1; i >= 0; i--) {
        vals[i] = slots[--_top];
        slots[_top] = null;
      }
      return vals;
    } else {
      List<Object?> vals = <Object?>[];
      for (int i = 0; i < n; i++) {
        vals.add(pop());
      }
      return vals.reversed.toList();
    }
  }

  /// Discards [n] values from the top without returning them.
  ///
  /// More efficient than calling [pop] in a loop when the values are not
  /// needed (e.g. [LuaStateImpl.pop]).
  void popDiscard(int n) {
    if (_fixed) {
      for (int i = 0; i < n; i++) {
        slots[--_top] = null;
      }
    } else {
      for (int i = 0; i < n; i++) {
        slots.removeAt(slots.length - 1);
      }
    }
  }

  /// Sets the logical stack top to [newTop], growing or shrinking as needed.
  ///
  /// Replaces the push/pop loops in [LuaStateImpl.setTop] with a single
  /// operation.
  void setTopDirect(int newTop) {
    if (_fixed) {
      if (newTop > _top) {
        _ensureCapacity(newTop);
        // New slots are already null from _grow / initial fill.
        // Null them out defensively in case of stale values from a prior frame.
        for (int i = _top; i < newTop; i++) {
          slots[i] = null;
        }
      } else {
        for (int i = newTop; i < _top; i++) {
          slots[i] = null;
        }
      }
      _top = newTop;
    } else {
      if (newTop > slots.length) {
        for (int i = slots.length; i < newTop; i++) {
          slots.add(null);
        }
      } else if (newTop < slots.length) {
        slots.length = newTop;
      }
    }
  }

  // ── Index helpers ────────────────────────────────────────────────────

  int absIndex(int idx) {
    return idx >= 0 || idx <= luaRegistryIndex ? idx : idx + top() + 1;
  }

  bool isValid(int idx) {
    if (idx < luaRegistryIndex) {
      /* upvalues */
      int uvIdx = luaRegistryIndex - idx - 1;
      return closure != null && uvIdx < closure!.upvals.length;
    }

    if (idx == luaRegistryIndex) {
      return true;
    }
    int absIdx = absIndex(idx);
    return absIdx > 0 && absIdx <= top();
  }

  Object? get(int idx) {
    if (idx < luaRegistryIndex) {
      /* upvalues */
      int uvIdx = luaRegistryIndex - idx - 1;
      if (closure != null &&
          closure!.upvals.length > uvIdx &&
          closure!.upvals[uvIdx] != null) {
        return closure!.upvals[uvIdx]!.get();
      } else {
        return null;
      }
    }

    if (idx == luaRegistryIndex) {
      return state.registry;
    }
    int absIdx = absIndex(idx);
    if (absIdx > 0 && absIdx <= top()) {
      return slots[absIdx - 1];
    } else {
      return null;
    }
  }

  void set(int idx, Object? val) {
    if (idx < luaRegistryIndex) {
      /* upvalues */
      int uvIdx = luaRegistryIndex - idx - 1;
      if (closure != null &&
          closure!.upvals.length > uvIdx &&
          closure!.upvals[uvIdx] != null) {
        closure!.upvals[uvIdx]!.set(val);
      }
      return;
    }

    if (idx == luaRegistryIndex) {
      state.registry = (val as LuaTable?);
      return;
    }
    int absIdx = absIndex(idx);
    slots[absIdx - 1] = val;
  }

  void reverse(int from, int to) {
    var obj;
    for (; from < to; from++, to--) {
      obj = slots[from];
      slots[from] = slots[to];
      slots[to] = obj;
    }
  }

  // ── Capacity management (fixed mode only) ────────────────────────────

  /// Ensures the backing array can hold at least [needed] elements.
  void _ensureCapacity(int needed) {
    if (needed <= slots.length) return;
    _grow(needed);
  }

  void _grow(int needed) {
    int newCap = slots.length == 0 ? _minCapacity : slots.length;
    do {
      newCap *= 2;
    } while (newCap < needed);
    final newSlots = List<Object?>.filled(newCap, null);
    for (int i = 0; i < _top; i++) {
      newSlots[i] = slots[i];
    }
    slots = newSlots;
  }

  // ── Debug / error helpers ────────────────────────────────────────────

  /// Fix #33: Get current source line number for error messages
  /// Returns the line number corresponding to the current instruction (pc),
  /// or null if line info is not available.
  int? getCurrentLine() {
    if (closure?.proto != null &&
        pc > 0 &&
        pc <= closure!.proto!.lineInfo.length) {
      return closure!.proto!.lineInfo[pc - 1];
    }
    return null;
  }

  /// Fix #33: Get source file name for error messages
  String? getSource() {
    return closure?.proto?.source;
  }

  /// Port of reference Lua 5.3's `luaO_chunkid` (lobject.c). The raw
  /// `source` attached to a prototype can be:
  ///   - `=<name>` — literal short name; strip the `=` and hard-truncate.
  ///   - `@<path>` — a file path; strip the `@`, and if too long, show the
  ///     tail with a leading `...`.
  ///   - otherwise — an actual chunk of source code (this is what
  ///     `loadString` installs when no explicit name is given). Format as
  ///     `[string "<first line, truncated>..."]` so error messages don't
  ///     drag in the entire script.
  ///
  /// [bufflen] matches C's `LUA_IDSIZE` (default 60), which is the size of
  /// the output buffer *including* the trailing NUL in C. We don't NUL-
  /// terminate in Dart, but we preserve the same effective truncation
  /// thresholds so output matches the reference implementation.
  static String chunkid(String source, {int bufflen = 60}) {
    if (source.isEmpty) return '?';
    final l = source.length;
    final first = source.codeUnitAt(0);
    if (first == 0x3D /* '=' */) {
      // `=literal`: strip the '='. If it fits in the buffer, keep as-is;
      // else take `bufflen - 1` chars (C reserves one slot for NUL).
      final s = source.substring(1);
      return l <= bufflen ? s : s.substring(0, bufflen - 1);
    }
    if (first == 0x40 /* '@' */) {
      // `@path`: strip the '@'. If it fits, keep as-is; else prepend '...'
      // and keep the tail that fits in `bufflen - LL("...")`.
      final s = source.substring(1);
      if (l <= bufflen) return s;
      final keep = bufflen - 3; // LL(RETS)
      return '...${s.substring(s.length - keep)}';
    }
    // String source: format as `[string "<inner>"]`, with `<inner>` being
    // the first line clamped to `bufflen - LL(PRE RETS POS) - 1`
    // ( = bufflen - (10 + 3 + 2) - 1 = bufflen - 16 with default 60 ).
    final nl = source.indexOf('\n');
    var inner = bufflen - 16; // LL(PRE) + LL(RETS) + LL(POS) + 1
    if (inner < 0) inner = 0;
    if (l < inner && nl < 0) {
      // Short, single-line source: keep it verbatim.
      return '[string "$source"]';
    }
    var cut = (nl >= 0) ? nl : l;
    if (cut > inner) cut = inner;
    return '[string "${source.substring(0, cut)}..."]';
  }

  /// If [rawSource] is an inline chunk of Lua source (i.e. not `=name`
  /// or `@path`), return the trimmed text of [line] (1-based). Otherwise
  /// return null. Used to enrich runtime error messages with the actual
  /// offending source line — something reference Lua can't do because
  /// its `proto.source` is typically just `@filename`, but we have the
  /// full source in-memory for `loadString` chunks.
  static String? sourceLine(String? rawSource, int line) {
    if (rawSource == null || rawSource.isEmpty || line <= 0) return null;
    final first = rawSource.codeUnitAt(0);
    if (first == 0x3D /* = */ || first == 0x40 /* @ */) return null;
    // Split lazily: scan for the (line-1)'th newline.
    var start = 0;
    var remaining = line - 1;
    while (remaining > 0) {
      final nl = rawSource.indexOf('\n', start);
      if (nl < 0) return null;
      start = nl + 1;
      remaining--;
    }
    final nl = rawSource.indexOf('\n', start);
    final end = nl < 0 ? rawSource.length : nl;
    final text = rawSource.substring(start, end).trim();
    return text.isEmpty ? null : text;
  }

  /// Fix #33: Format error message with line number.
  ///
  /// When the chunk's source is an inline string (typical for
  /// `loadString`), also append the offending source line so the user
  /// doesn't have to count lines by hand:
  ///
  ///   [string "..."]:103: attempt to index a nil value
  ///     > local day_len_sec = s.day_length or 0
  String formatError(String message) {
    final line = getCurrentLine();
    final rawSource = getSource();
    final source = rawSource == null ? 'unknown' : chunkid(rawSource);
    final prefix =
        line != null ? '[$source:$line] $message' : '[$source] $message';
    if (line == null) return prefix;
    final snippet = sourceLine(rawSource, line);
    if (snippet == null) return prefix;
    // Clamp extremely long lines so the message stays readable.
    const maxSnippet = 200;
    final shown = snippet.length <= maxSnippet
        ? snippet
        : '${snippet.substring(0, maxSnippet)}...';
    return '$prefix\n  > $shown';
  }
}
