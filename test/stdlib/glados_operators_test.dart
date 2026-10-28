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
  // ──────── Integer arithmetic ────────

  group('Integer arithmetic', () {
    Glados2(any.intInRange(-10000, 10000), any.intInRange(-10000, 10000)).test(
      '(a + b) - b == a',
      (a, b) {
        final r = _run('return ($a + $b) - $b == $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-10000, 10000), any.intInRange(-10000, 10000)).test(
      'a + b == b + a (commutativity)',
      (a, b) {
        final r = _run('return $a + $b == $b + $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      'a * b == b * a (commutativity)',
      (a, b) {
        final r = _run('return $a * $b == $b * $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'a * 0 == 0',
      (a) {
        final r = _run('return $a * 0 == 0', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'a * 1 == a',
      (a) {
        final r = _run('return $a * 1 == $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      '-(-a) == a',
      (a) {
        // Parenthesize to avoid --N being parsed as a comment
        final r = _run('local a = $a; return -(-a) == a', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── Integer division and modulo ────────

  group('Integer division / modulo', () {
    Glados2(any.intInRange(-1000, 1000), any.intInRange(1, 1000)).test(
      'a // b * b + a % b == a',
      (a, b) {
        final r = _run('return $a // $b * $b + $a % $b == $a', 1);
        expect(r?[0], equals('true'), reason: 'a=$a b=$b');
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(1, 1000)).test(
      'a % b has same sign as b (Lua floor division)',
      (a, b) {
        final r = _run('''
          local r = $a % $b
          if r == 0 then return true end
          return (r > 0) == ($b > 0)
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, -1)).test(
      'a // b * b + a % b == a (negative divisor)',
      (a, b) {
        final r = _run('return $a // ($b) * ($b) + $a % ($b) == $a', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── Comparison operators ────────

  group('Comparison operators', () {
    Glados(any.intInRange(-10000, 10000)).test(
      'a == a',
      (a) {
        final r = _run('return $a == $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'not (a ~= a)',
      (a) {
        final r = _run('return not ($a ~= $a)', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(-10000, 10000)).test(
      'a <= a',
      (a) {
        final r = _run('return $a <= $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      '(a < b) == (b > a)',
      (a, b) {
        final r = _run('return ($a < $b) == ($b > $a)', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(-1000, 1000), any.intInRange(-1000, 1000)).test(
      '(a <= b) == (b >= a)',
      (a, b) {
        final r = _run('return ($a <= $b) == ($b >= $a)', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── Bitwise operators ────────

  group('Bitwise operators', () {
    Glados(any.intInRange(0, 0xFFFF)).test(
      'a & a == a (idempotent)',
      (a) {
        final r = _run('return $a & $a == $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(0, 0xFFFF)).test(
      'a | a == a',
      (a) {
        final r = _run('return $a | $a == $a', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(0, 0xFFFF)).test(
      'a ~ a == 0 (XOR self)',
      (a) {
        final r = _run('return $a ~ $a == 0', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(0, 0xFFFF), any.intInRange(0, 0xFFFF)).test(
      'a & b == b & a',
      (a, b) {
        final r = _run('return ($a & $b) == ($b & $a)', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(0, 0xFFFF), any.intInRange(0, 0xFFFF)).test(
      'a | b == b | a',
      (a, b) {
        final r = _run('return ($a | $b) == ($b | $a)', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(0, 255), any.intInRange(0, 16)).test(
      '(a << n) >> n == a for small n and a',
      (a, n) {
        final r = _run('return ($a << $n) >> $n == $a', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── String concatenation ────────

  group('String concatenation', () {
    Glados2(any.intInRange(0, 20), any.intInRange(0, 20)).test(
      '#(s1 .. s2) == #s1 + #s2',
      (n1, n2) {
        final r = _run('''
          local s1 = string.rep("a", $n1)
          local s2 = string.rep("b", $n2)
          return #(s1 .. s2) == #s1 + #s2
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(0, 10)).test(
      '"" .. s == s',
      (n) {
        final r = _run('''
          local s = string.rep("x", $n)
          return "" .. s == s
        ''', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── Logical operators ────────

  group('Logical operators', () {
    Glados(any.intInRange(-100, 100)).test(
      'not not x == true for non-nil non-false',
      (x) {
        final r = _run('return not not $x == true', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(1, 100), any.intInRange(1, 100)).test(
      'a and b == b when both truthy',
      (a, b) {
        final r = _run('return ($a and $b) == $b', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados2(any.intInRange(1, 100), any.intInRange(1, 100)).test(
      'a or b == a when a is truthy',
      (a, b) {
        final r = _run('return ($a or $b) == $a', 1);
        expect(r?[0], equals('true'));
      },
    );
  });

  // ──────── tostring / tonumber round-trip ────────

  group('tostring/tonumber', () {
    Glados(any.intInRange(-100000, 100000)).test(
      'tonumber(tostring(n)) == n',
      (n) {
        final r = _run('return tonumber(tostring($n)) == $n', 1);
        expect(r?[0], equals('true'));
      },
    );

    Glados(any.intInRange(2, 36)).test(
      'tonumber with base: round-trip for base b',
      (b) {
        // Convert 255 to string in base b, then back
        final r = _run('''
          -- string.format only does decimal, so just test the parser
          local n = tonumber("10", $b)
          return n == $b
        ''', 1);
        expect(r?[0], equals('true'),
            reason: 'tonumber("10", $b) should be $b');
      },
    );
  });

  // ──────── pcall / error ────────

  group('pcall / error', () {
    Glados(any.intInRange(-1000, 1000)).test(
      'pcall on success returns true and value',
      (n) {
        final r = _run('''
          local ok, v = pcall(function() return $n end)
          return ok, v
        ''', 2);
        expect(r?[0], equals('true'));
        expect(r?[1], equals('$n'));
      },
    );

    Glados(any.intInRange(-1000, 1000)).test(
      'pcall on error returns false',
      (n) {
        final r = _run('''
          local ok, v = pcall(function() error($n) end)
          return ok
        ''', 1);
        expect(r?[0], equals('false'));
      },
    );
  });

  // ──────── select ────────

  group('select', () {
    Glados(any.intInRange(1, 10)).test(
      'select("#", ...) counts correctly',
      (n) {
        final args = List.generate(n, (i) => '${i + 1}').join(', ');
        final r = _run('return select("#", $args)', 1);
        expect(r?[0], equals('$n'));
      },
    );
  });

  // ──────── Coroutine basics ────────

  group('Coroutine', () {
    // Single yield/resume works correctly.
    Glados(any.intInRange(1, 100)).test(
      'single yield passes value out',
      (n) {
        final r = _run('''
          local co = coroutine.create(function()
            coroutine.yield($n)
          end)
          local ok, v = coroutine.resume(co)
          return v
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );

    Glados(any.intInRange(1, 100)).test(
      'single yield receives value from resume',
      (n) {
        final r = _run('''
          local co = coroutine.create(function()
            local v = coroutine.yield()
            return v
          end)
          coroutine.resume(co)
          local ok, v = coroutine.resume(co, $n)
          return v
        ''', 1);
        expect(r?[0], equals('$n'));
      },
    );

    test('coroutine.status transitions', () {
      final r = _run('''
        local co = coroutine.create(function() coroutine.yield() end)
        local s1 = coroutine.status(co)
        coroutine.resume(co)
        local s2 = coroutine.status(co)
        coroutine.resume(co)
        local s3 = coroutine.status(co)
        return s1, s2, s3
      ''', 3);
      expect(r?[0], equals('suspended'));
      expect(r?[1], equals('suspended'));
      expect(r?[2], equals('dead'));
    });

    test('multi-resume yield accumulator', () {
      final r = _run('''
        local co = coroutine.create(function()
          local sum = 0
          for i = 1, 3 do
            local v = coroutine.yield()
            sum = sum + v
          end
          return sum
        end)
        coroutine.resume(co)
        coroutine.resume(co, 10)
        coroutine.resume(co, 20)
        local ok, result = coroutine.resume(co, 30)
        if ok then return result else return -1 end
      ''', 1);
      expect(r?[0], equals('60'));
    });

    Glados(any.intInRange(1, 20)).test(
      'yield n times then sum resume values',
      (n) {
        final r = _run('''
          local co = coroutine.create(function()
            local sum = 0
            for i = 1, $n do
              local v = coroutine.yield(i)
              sum = sum + v
            end
            return sum
          end)
          local total = 0
          local ok, yielded = coroutine.resume(co)
          for i = 1, $n do
            ok, yielded = coroutine.resume(co, i * 10)
          end
          return yielded
        ''', 1);
        final expected =
            Iterable.generate(n, (i) => (i + 1) * 10).reduce((a, b) => a + b);
        expect(r?[0], equals('$expected'));
      },
    );

    Glados(any.intInRange(1, 15)).test(
      'yield passes values both directions',
      (n) {
        final r = _run('''
          local co = coroutine.create(function()
            local sum = 0
            for i = 1, $n do
              local v = coroutine.yield(sum)
              sum = sum + v
            end
            return sum
          end)
          coroutine.resume(co)
          local ok, v
          for i = 1, $n do
            ok, v = coroutine.resume(co, i)
          end
          return v
        ''', 1);
        final expected = n * (n + 1) ~/ 2;
        expect(r?[0], equals('$expected'));
      },
    );
  });
}
