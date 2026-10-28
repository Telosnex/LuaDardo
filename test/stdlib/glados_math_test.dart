// glados generates inputs with 1 << 32, which is 0 under dart2js.
@TestOn('!dart2js')
library;

import 'package:glados/glados.dart';
import 'package:lua_dardo_plus/lua.dart';

/// Run a Lua snippet, returning up to [n] results as strings.
/// Booleans are stringified. Returns null on error.
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
  // ──────────────── math ────────────────

  group('math: floor/ceil', () {
    Glados(any.intInRange(-10000, 10000)).test(
      'floor(n) == n for integers',
      (n) {
        final r = _run('return math.floor($n)', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'ceil(n) == n for integers',
      (n) {
        final r = _run('return math.ceil($n)', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'floor(n + 0.5) == n or n+1',
      (n) {
        final r = _run(
            'local f = math.floor($n + 0.5); return f >= $n and f <= $n + 1',
            1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: abs', () {
    Glados(any.intInRange(-100000, 100000)).test(
      'abs(n) >= 0',
      (n) {
        final r = _run('return math.abs($n) >= 0', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(0, 100000)).test(
      'abs(-n) == abs(n)',
      (n) {
        final r = _run('return math.abs(-$n) == math.abs($n)', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: min/max', () {
    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      'max(a,b) >= a and max(a,b) >= b',
      (a, b) {
        final r =
            _run('local m = math.max($a,$b); return m >= $a and m >= $b', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      'min(a,b) <= a and min(a,b) <= b',
      (a, b) {
        final r =
            _run('local m = math.min($a,$b); return m <= $a and m <= $b', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      'max(a,b) == a or max(a,b) == b',
      (a, b) {
        final r =
            _run('local m = math.max($a,$b); return m == $a or m == $b', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: trig', () {
    Glados(any.intInRange(-314, 314)).test(
      'sin(x) in [-1,1]',
      (n) {
        final x = n / 100.0;
        final r = _run('local s = math.sin($x); return s >= -1 and s <= 1', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-314, 314)).test(
      'cos(x) in [-1,1]',
      (n) {
        final x = n / 100.0;
        final r = _run('local c = math.cos($x); return c >= -1 and c <= 1', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-314, 314)).test(
      'sin(x)^2 + cos(x)^2 ≈ 1',
      (n) {
        final x = n / 100.0;
        final r = _run(
            'local s,c = math.sin($x),math.cos($x); return math.abs(s*s+c*c - 1) < 1e-10',
            1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: exp/log round-trip', () {
    Glados(any.intInRange(1, 1000)).test(
      'exp(log(x)) ≈ x for x > 0',
      (n) {
        final x = n / 10.0;
        final r =
            _run('return math.abs(math.exp(math.log($x)) - $x) < 1e-8', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-100, 100)).test(
      'log(exp(x)) ≈ x',
      (n) {
        final x = n / 10.0;
        final r =
            _run('return math.abs(math.log(math.exp($x)) - $x) < 1e-8', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: sqrt', () {
    Glados(any.intInRange(0, 100000)).test(
      'sqrt(x)^2 ≈ x',
      (n) {
        final r = _run(
            'local s = math.sqrt($n); return math.abs(s*s - $n) < 1e-6', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: random', () {
    Glados2(any.intInRange(1, 50), any.intInRange(51, 100)).test(
      'random(a,b) in [a,b]',
      (a, b) {
        final r = _run('''
          for i = 1, 20 do
            local v = math.random($a, $b)
            if v < $a or v > $b then return false end
          end
          return true
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(1, 100)).test(
      'random(n) in [1,n]',
      (n) {
        final r = _run('''
          for i = 1, 20 do
            local v = math.random($n)
            if v < 1 or v > $n then return false end
          end
          return true
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: fmod', () {
    Glados2(any.intInRange(-100, 100), any.intInRange(1, 100)).test(
      'fmod(a,b) has same sign as a',
      (a, b) {
        if (a == 0) return;
        final r = _run('''
          local r = math.fmod($a, $b)
          if r == 0 then return true end
          return (r > 0) == ($a > 0)
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: modf', () {
    Glados(any.intInRange(-10000, 10000)).test(
      'modf integer + fractional = original',
      (n) {
        final x = n / 7.0;
        final r = _run('''
          local i, f = math.modf($x)
          return math.abs((i + f) - $x) < 1e-10
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  group('math: type', () {
    Glados(any.intInRange(-1000, 1000)).test(
      'math.type(integer) == "integer"',
      (n) {
        final r = _run('return math.type($n)', 1);
        expect(r?[0], equals('integer'));
      },
    );

    Glados(any.intInRange(-1000, 1000)).test(
      'math.type(float) == "float"',
      (n) {
        final r = _run('return math.type($n + 0.0)', 1);
        expect(r?[0], equals('float'));
      },
    );
  });
}
