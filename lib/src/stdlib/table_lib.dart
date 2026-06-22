// ignore_for_file: constant_identifier_names

import '../api/lua_state.dart';
import '../api/lua_type.dart';

const MAX_LEN = 1000000; // TODO

///
/// Operations that an object must define to mimic a table
/// (some functions only need some of them)
const TAB_R = 1; /* read */
const TAB_W = 2; /* write */
const TAB_L = 4; /* length */
const TAB_RW = (TAB_R | TAB_W); /* read/write */

class TableLib {
  /// `table.sort` uses introsort: median-of-three quicksort for the common
  /// case, insertion sort for tiny partitions, and heapsort as a
  /// recursion-depth fallback to preserve O(n log n) worst-case behavior.
  ///
  /// Reference: https://every-algorithm.github.io/2023/11/20/introsort.html
  static const Map<String, DartFunction> _tabFuncs = {
    "move": _tabMove,
    "insert": _tabInsert,
    "remove": _tabRemove,
    "sort": _tabSort,
    "concat": _tabConcat,
    "pack": _tabPack,
    "unpack": _tabUnpack,
  };

  static int openTableLib(LuaState ls) {
    ls.newLib(_tabFuncs);
    return 1;
  }

  // table.move (a1, f, e, t [,a2])
// http://www.lua.org/manual/5.3/manual.html#pdf-table.move
// lua-5.3.4/src/ltablib.c#tremove()
  static int _tabMove(LuaState ls) {
    var f = ls.checkInteger(2)!;
    var e = ls.checkInteger(3)!;
    var t = ls.checkInteger(4);
    var tt = 1; /* destination table */
    if (!ls.isNoneOrNil(5)) {
      tt = 5;
    }
    _checkTab(ls, 1, TAB_R);
    _checkTab(ls, tt, TAB_W);
    if (e >= f) {
      /* otherwise, nothing to move */
      int i;
      ls.argCheck(
          f > 0 || e < luaMaxInteger + f, 3, "too many elements to move");
      var n = e - f + 1; /* number of elements to move */
      ls.argCheck(t! <= luaMaxInteger - n + 1, 4, "destination wrap around");
      if (t > e || t <= f || (tt != 1 && !ls.compare(1, tt, CmpOp.luaOpEq))) {
        for (i = 0; i < n; i++) {
          ls.getI(1, f + i);
          ls.setI(tt, t + i);
        }
      } else {
        for (i = n - 1; i >= 0; i--) {
          ls.getI(1, f + i);
          ls.setI(tt, t + i);
        }
      }
    }
    ls.pushValue(tt); /* return destination table */
    return 1;
  }

// table.insert (list, [pos,] value)
// http://www.lua.org/manual/5.3/manual.html#pdf-table.insert
// lua-5.3.4/src/ltablib.c#tinsert()
  static int _tabInsert(LuaState ls) {
    var e = _auxGetN(ls, 1, TAB_RW)! + 1; /* first empty element */
    int? pos; /* where to insert new element */
    switch (ls.getTop()) {
      case 2:
        /* called with only 2 arguments */
        pos = e;
        /* insert new element at the end */
        break;
      case 3:
        pos = ls.checkInteger(2);
        /* 2nd argument is the position */
        ls.argCheck(1 <= pos! && pos <= e, 2, "position out of bounds");
        for (var i = e; i > pos; i--) {
          /* move up elements */
          ls.getI(1, i - 1);
          ls.setI(1, i); /* t[i] = t[i - 1] */
        }
        break;
      default:
        return ls.error2("wrong number of arguments to 'insert'");
    }
    ls.setI(1, pos); /* t[pos] = v */
    return 0;
  }

// table.remove (list [, pos])
// http://www.lua.org/manual/5.3/manual.html#pdf-table.remove
// lua-5.3.4/src/ltablib.c#tremove()
  static int _tabRemove(LuaState ls) {
    var size = _auxGetN(ls, 1, TAB_RW)!;
    var pos = ls.optInteger(2, size)!;
    if (pos != size) {
      /* validate 'pos' if given */
      ls.argCheck(1 <= pos && pos <= size + 1, 1, "position out of bounds");
    }
    ls.getI(1, pos); /* result = t[pos] */
    for (; pos < size; pos++) {
      ls.getI(1, pos + 1);
      ls.setI(1, pos); /* t[pos] = t[pos + 1] */
    }
    ls.pushNil();
    ls.setI(1, pos); /* t[pos] = nil */
    return 1;
  }

// table.concat (list [, sep [, i [, j]]])
// http://www.lua.org/manual/5.3/manual.html#pdf-table.concat
// lua-5.3.4/src/ltablib.c#tconcat()
  static int _tabConcat(LuaState ls) {
    var tabLen = _auxGetN(ls, 1, TAB_R);
    var sep = ls.optString(2, "");
    var i = ls.optInteger(3, 1)!;
    var j = ls.optInteger(4, tabLen)!;

    if (i > j) {
      ls.pushString("");
      return 1;
    }

    var buf = List<String?>.filled(j - i + 1, null);
    for (var k = i; k > 0 && k <= j; k++) {
      ls.getI(1, k);
      if (!ls.isString(-1)) {
        ls.error2("invalid value (%s) at index %d in table for 'concat'",
            [ls.typeName2(-1), i]);
      }
      buf[k - i] = ls.toStr(-1);
      ls.pop(1);
    }
    ls.pushString(buf.join(sep!));

    return 1;
  }

  static int? _auxGetN(LuaState ls, int n, int w) {
    _checkTab(ls, n, w | TAB_L);
    return ls.len2(n);
  }

/*
** Check that 'arg' either is a table or can behave like one (that is,
** has a metatable with the required metamethods)
 */
  static _checkTab(LuaState ls, int arg, int what) {
    if (ls.type(arg) != LuaType.luaTable) {
      /* is it not a table? */
      var n = 1; /* number of elements to pop */
      var nL = List<int>.filled(1, 0)..[0] = n;
      if (ls.getMetatable(arg) && /* must have metatable */
          (what & TAB_R == 0 || _checkField(ls, "__index", nL)) &&
          (what & TAB_W == 0 || _checkField(ls, "__newindex", nL)) &&
          (what & TAB_L == 0 || _checkField(ls, "__len", nL))) {
        ls.pop(n); /* pop metatable and tested metamethods */
      } else {
        ls.checkType(arg, LuaType.luaTable); /* force an error */
      }
    }
  }

  static bool _checkField(LuaState ls, String key, List<int> nL) {
    ls.pushString(key);
    nL[0]++;
    return ls.rawGet(-nL[0]) != LuaType.luaNil;
  }

/* Pack/unpack */

// table.pack (···)
// http://www.lua.org/manual/5.3/manual.html#pdf-table.pack
// lua-5.3.4/src/ltablib.c#pack()
  static int _tabPack(LuaState ls) {
    var n = ls.getTop(); /* number of elements to pack */
    ls.createTable(n, 1); /* create result table */
    ls.insert(1); /* put it at index 1 */
    for (var i = n; i >= 1; i--) {
      /* assign elements */
      ls.setI(1, i);
    }
    ls.pushInteger(n);
    ls.setField(1, "n"); /* t.n = number of elements */
    return 1; /* return table */
  }

// table.unpack (list [, i [, j]])
// http://www.lua.org/manual/5.3/manual.html#pdf-table.unpack
// lua-5.3.4/src/ltablib.c#unpack()
  static int _tabUnpack(LuaState ls) {
    var i = ls.optInteger(2, 1)!;
    var e = ls.optInteger(3, ls.len2(1))!;
    if (i > e) {
      /* empty range */
      return 0;
    }

    var n = e - i + 1;
    if (n <= 0 || n >= MAX_LEN || !ls.checkStack(n)) {
      return ls.error2("too many results to unpack");
    }

    for (; i < e; i++) {
      /* push arg[i..e - 1] (to avoid overflows) */
      ls.getI(1, i);
    }
    ls.getI(1, e); /* push last element */
    return n;
  }

/* sort */

// table.sort (list [, comp])
// http://www.lua.org/manual/5.3/manual.html#pdf-table.sort
  static int _tabSort(LuaState ls) {
    var sort = _SortHelper(ls);
    var len = sort.len()!;
    ls.argCheck(len < MAX_LEN, 1, "array too big");
    sort.introSort(0, len - 1);
    return 0;
  }
}

class _SortHelper {
  static const _insertionSortCutoff = 16;

  LuaState ls;

  _SortHelper(this.ls);

  int? len() {
    return ls.len2(1);
  }

  bool _less(int i, int j) {
    if (ls.isFunction(2)) {
      // cmp is given
      ls.pushValue(2);
      ls.getI(1, i + 1);
      ls.getI(1, j + 1);
      ls.call(2, 1);
      var b = ls.toBoolean(-1);
      ls.pop(1);
      return b;
    } else {
      // cmp is missing
      ls.getI(1, i + 1);
      ls.getI(1, j + 1);
      var b = ls.compare(-2, -1, CmpOp.luaOpLt);
      ls.pop(2);
      return b;
    }
  }

  void _swap(int i, int j) {
    ls.getI(1, i + 1);
    ls.getI(1, j + 1);
    ls.setI(1, i + 1);
    ls.setI(1, j + 1);
  }

  int _partition(int low, int high) {
    int i = low;
    int j = high + 1;

    while (true) {
      // find item on low to swap
      while (_less(++i, low)) {
        if (i == high) {
          break;
        }
      }

      // find item on high to swap
      while (_less(low, --j)) {
        if (j == low) {
          break;
        }
      }

      // check if pointers cross
      if (i >= j) {
        break;
      }

      _swap(i, j);
    }
    _swap(low, j);
    return j;
  }

  int _medianOfThree(int low, int mid, int high) {
    // After these swaps: table[low] <= table[mid] <= table[high]. Returning
    // [mid] gives quicksort a robust pivot for already-sorted/reverse-sorted
    // input, which is the pathological case for the old first-element pivot.
    if (_less(mid, low)) {
      _swap(low, mid);
    }
    if (_less(high, mid)) {
      _swap(mid, high);
      if (_less(mid, low)) {
        _swap(low, mid);
      }
    }
    return mid;
  }

  void _insertionSort(int low, int high) {
    for (var i = low + 1; i <= high; i++) {
      for (var j = i; j > low && _less(j, j - 1); j--) {
        _swap(j, j - 1);
      }
    }
  }

  /// Sorts [low]..[high] with introsort.
  ///
  /// Introsort starts with quicksort because it is fast in practice, but tracks
  /// recursion depth. If partitioning gets too deep, it switches that partition
  /// to heapsort, which prevents adversarial inputs from degrading quicksort to
  /// O(n²). Small partitions are finished with insertion sort to reduce
  /// comparator/stack overhead.
  ///
  /// Reference: https://every-algorithm.github.io/2023/11/20/introsort.html
  void introSort(int low, int high) {
    _introSort(low, high, _maxDepth(high - low + 1));
  }

  void _introSort(int low, int high, int depthLimit) {
    // Sort the smaller partition recursively and loop over the larger one.
    // This caps Dart call-stack usage at O(log n), even with unlucky pivots.
    while (high - low > _insertionSortCutoff) {
      if (depthLimit == 0) {
        _heapSort(low, high);
        return;
      }
      depthLimit--;

      final mid = low + ((high - low) >> 1);
      final pivot = _medianOfThree(low, mid, high);
      _swap(low, pivot);

      final pi = _partition(low, high);
      if (pi - low < high - pi) {
        _introSort(low, pi - 1, depthLimit);
        low = pi + 1;
      } else {
        _introSort(pi + 1, high, depthLimit);
        high = pi - 1;
      }
    }

    if (low < high) {
      _insertionSort(low, high);
    }
  }

  void _heapSort(int low, int high) {
    final count = high - low + 1;

    for (var start = (count - 2) >> 1; start >= 0; start--) {
      _siftDown(low, start, count - 1);
      if (start == 0) {
        break;
      }
    }

    for (var end = count - 1; end > 0; end--) {
      _swap(low, low + end);
      _siftDown(low, 0, end - 1);
    }
  }

  void _siftDown(int offset, int start, int end) {
    var root = start;

    while (true) {
      final child = root * 2 + 1;
      if (child > end) {
        return;
      }

      var swapIndex = root;
      if (_less(offset + swapIndex, offset + child)) {
        swapIndex = child;
      }
      if (child + 1 <= end && _less(offset + swapIndex, offset + child + 1)) {
        swapIndex = child + 1;
      }
      if (swapIndex == root) {
        return;
      }

      _swap(offset + root, offset + swapIndex);
      root = swapIndex;
    }
  }

  /// Depth budget used by introsort before falling back to heapsort.
  ///
  /// The conventional limit is `2 * floor(log2(n))`: generous enough that
  /// normal quicksort behavior stays on the fast path, but low enough to catch
  /// repeatedly unbalanced/adversarial partitions before they become quadratic.
  int _maxDepth(int length) => length <= 1 ? 0 : 2 * (length.bitLength - 1);
}
