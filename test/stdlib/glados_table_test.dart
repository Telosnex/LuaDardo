// glados generates inputs with 1 << 32, which is 0 under dart2js.
@TestOn('!dart2js')
library;

import 'package:glados/glados.dart';
import 'package:lua_dardo_plus/lua.dart';

List<String?>? _run(String code, int n) {
  try {
    final ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(code);
    ls.call(0, n);
    final r = <String?>[];
    for (var i = 0; i < n; i++) {
      final idx = -(n - i);
      if (ls.isNil(idx)) {
        r.add(null);
      } else if (ls.type(idx) == LuaType.luaBoolean) {
        r.add(ls.toBoolean(idx) ? 'true' : 'false');
      } else {
        r.add(ls.toStr(idx));
      }
    }
    return r;
  } catch (_) {
    return null;
  }
}

void main() {
  group('table.insert / #t', () {
    Glados(any.intInRange(1, 20)).test(
      'n inserts into empty table gives #t == n',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do table.insert(t, i) end
          return #t
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(1, 20)).test(
      'insert at 1 makes it the first element',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do table.insert(t, 1, i) end
          return t[1]
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );
  });

  group('table.remove', () {
    Glados(any.intInRange(1, 20)).test(
      'remove decreases length by 1',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i end
          table.remove(t)
          return #t
        ''', 1);
        expect(r?[0], equals('${n - 1}'));
      },
    );

    Glados(any.intInRange(2, 20)).test(
      'remove(t,1) shifts elements down',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i end
          table.remove(t, 1)
          return t[1], #t
        ''', 2);
        expect(r?[0], equals('2'));
        expect(r?[1], equals('${n - 1}'));
      },
    );
  });

  group('table.sort', () {
    Glados(any.intInRange(1, 30)).test(
      'sort produces non-decreasing order',
      (n) {
        final r = _run('''
          math.randomseed(42)
          local t = {}
          for i = 1, $n do t[i] = math.random(1, 1000) end
          table.sort(t)
          for i = 2, #t do
            if t[i] < t[i-1] then return false end
          end
          return true
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(1, 30)).test(
      'sort preserves length',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = $n - i end
          table.sort(t)
          return #t
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(1, 20)).test(
      'sort with custom comparator reverses order',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i end
          table.sort(t, function(a,b) return a > b end)
          return t[1], t[#t]
        ''', 2);
        expect(r?[0], equals('$n'));
        expect(r?[1], equals('1'));
      },
    );
  });

  group('table.concat', () {
    Glados(any.intInRange(1, 20)).test(
      'concat with "," has n-1 commas',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = "x" end
          local s = table.concat(t, ",")
          local count = 0
          for _ in string.gmatch(s, ",") do count = count + 1 end
          return count
        ''', 1);
        expect(r?[0], equals('${n - 1}'));
      },
    );

    Glados(any.intInRange(1, 20)).test(
      'concat with "" joins without separator',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = "a" end
          return #table.concat(t, "")
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );
  });

  group('table.move', () {
    Glados(any.intInRange(1, 10)).test(
      'move(t,1,#t,#t+1) doubles the array',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i end
          table.move(t, 1, $n, ${n + 1})
          return #t, t[1], t[${n + 1}]
        ''', 3);
        expect(r?[0], equals('${n * 2}'));
        expect(r?[1], equals('1'));
        expect(r?[2], equals('1'));
      },
    );
  });

  group('table: ipairs iteration', () {
    Glados(any.intInRange(0, 20)).test(
      'ipairs visits exactly #t elements',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i * 10 end
          local count = 0
          for _ in ipairs(t) do count = count + 1 end
          return count
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(1, 20)).test(
      'ipairs sum matches n*(n+1)/2 * 10',
      (n) {
        final expected = n * (n + 1) ~/ 2 * 10;
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = i * 10 end
          local sum = 0
          for _, v in ipairs(t) do sum = sum + v end
          return sum
        ''', 1);
        expect(r?[0], equals('$expected'));
      },
    );
  });

  group('table: pairs on array', () {
    Glados(any.intInRange(1, 20)).test(
      'pairs visits all keys of an array table',
      (n) {
        final r = _run('''
          local t = {}
          for i = 1, $n do t[i] = true end
          local count = 0
          for _ in pairs(t) do count = count + 1 end
          return count
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );
  });
}
