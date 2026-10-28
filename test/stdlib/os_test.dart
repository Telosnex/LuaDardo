import 'package:lua_dardo_plus/lua.dart';
import 'package:test/test.dart';

bool testOS() {
  try {
    LuaState state = LuaState.newState();
    state.openLibs();
    state.loadString(r'''
local start = os.clock()

local s = 0
for i = 1, 100000 do
      s = s + i;
end

print('sec:'..(os.clock()-start)) 
''');
    state.pCall(0, 0, 1);
  } catch (e, s) {
    print('$e\n$s');
    return false;
  }
  return true;
}

void main() {
  test('os.clock returns a small number (not epoch seconds)', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.clock()');
    ls.call(0, 1);
    var clock = ls.toNumber(-1);
    // Should be process CPU-ish time, not epoch (which would be > 1e9)
    expect(clock, lessThan(1000000));
  });

  test('os.date with format string %Y-%m-%d', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%Y-%m-%d")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    // Should be like "2026-02-27", not "%Y-%m-%d"
    expect(result, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
  });

  test('os.date with format %H:%M:%S', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%H:%M:%S")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, matches(RegExp(r'^\d{2}:\d{2}:\d{2}$')));
  });

  test('os.date with %A weekday name', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%A")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, isNot(equals('%A')));
  });

  test('os.date with explicit epoch time', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 0 epoch = Jan 1 1970 UTC
    ls.loadString(r'return os.date("!%Y-%m-%d", 0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('1970-01-01'));
  });

  test('os.date with known epoch time', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 1000000000 = 2001-09-09 UTC
    ls.loadString(r'return os.date("!%Y-%m-%d", 1000000000)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('2001-09-09'));
  });

  test('lua OS standard library test', () {
    expect(testOS(), true);
  });

  // ── wday: 1 = Sunday per Lua spec ──────────────────────────────────

  test('os.date *t wday: Sunday is 1', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 2001-09-09 01:46:40 UTC was a Sunday
    ls.loadString(r'return os.date("!*t", 1000000000).wday');
    ls.call(0, 1);
    expect(ls.toInteger(-1), equals(1));
  });

  test('os.date *t wday: Monday is 2', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 2001-09-10 01:46:40 UTC was a Monday
    ls.loadString(r'return os.date("!*t", 1000086400).wday');
    ls.call(0, 1);
    expect(ls.toInteger(-1), equals(2));
  });

  test('os.date *t wday: Saturday is 7', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 2001-09-08 01:46:40 UTC was a Saturday
    ls.loadString(r'return os.date("!*t", 999913600).wday');
    ls.call(0, 1);
    expect(ls.toInteger(-1), equals(7));
  });

  // ── %Y zero-padding ────────────────────────────────────────────────

  test('os.date %Y pads year to 4 digits', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 1970-01-01 00:00:00 UTC → year "1970"
    ls.loadString(r'return os.date("!%Y", 0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('1970'));
  });

  // ── %c (C-locale strftime format) ──────────────────────────────────

  test('os.date %c produces strftime-style output', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 1000000000 = Sun Sep  9 01:46:40 2001 UTC
    ls.loadString(r'return os.date("!%c", 1000000000)');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, equals('Sun Sep 09 01:46:40 2001'));
  });

  test('os.date bare %c format (no other specifiers)', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%c")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    // Should look like "Mon Apr 14 15:30:00 2025", not Dart's toString()
    expect(
        result,
        matches(RegExp(
            r'^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{2} \d{2}:\d{2}:\d{2} \d{4}$')));
  });

  // ── %Z and %z (timezone specifiers) ────────────────────────────────

  test('os.date !%Z returns UTC', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("!%Z", 0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('UTC'));
  });

  test('os.date !%z returns +0000', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("!%z", 0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('+0000'));
  });

  test('os.date %Z returns non-empty timezone name', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%Z")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result.length, greaterThan(0));
    // Should not be the literal "%Z"
    expect(result, isNot(equals('%Z')));
  });

  test('os.date %z returns numeric offset like +HHMM or -HHMM', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.date("%z")');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, matches(RegExp(r'^[+-]\d{4}$')));
  });

  // ── os.time with bad args ──────────────────────────────────────────

  test('os.time with non-table arg throws', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return os.time("hello")');
    expect(() => ls.call(0, 1), throwsA(anything));
  });
}
