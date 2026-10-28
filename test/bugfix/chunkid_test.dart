import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/src/state/lua_stack.dart';
import 'package:test/test.dart';

/// Verifies that runtime error messages don't embed the entire script source
/// as the chunk id, matching reference Lua 5.3's `luaO_chunkid` behavior.
void main() {
  group('chunkid truncation (luaO_chunkid port)', () {
    test('"=name" short form strips the = and keeps the name', () {
      expect(LuaStack.chunkid('=short'), 'short');
    });

    test('"=name" long form hard-truncates to bufflen - 1', () {
      final longName = '=${'x' * 200}';
      final id = LuaStack.chunkid(longName);
      // bufflen defaults to 60 -> output length 59
      expect(id.length, 59);
      expect(id, 'x' * 59);
    });

    test('"@path" short form strips the @', () {
      expect(LuaStack.chunkid('@foo/bar.lua'), 'foo/bar.lua');
    });

    test('"@path" long form uses "..." + tail', () {
      final path = '@${'a' * 100}/last.lua';
      final id = LuaStack.chunkid(path);
      expect(id.startsWith('...'), isTrue);
      expect(id.endsWith('/last.lua'), isTrue);
      // bufflen 60 -> output length 60 (3 for '...' + 57 tail chars)
      expect(id.length, 60);
    });

    test('raw source with newline clamps to first line and adds "..."', () {
      const source = 'local x = 1\nlocal y = 2\nprint(x+y)';
      final id = LuaStack.chunkid(source);
      expect(id, '[string "local x = 1..."]');
    });

    test('raw source long single line clamps to inner budget', () {
      final source = 'print(${'"hello" .. ' * 50}nil)';
      final id = LuaStack.chunkid(source);
      expect(id.startsWith('[string "'), isTrue);
      expect(id.endsWith('..."]'), isTrue);
      // inner budget = bufflen - 16 = 44; plus wrapping '[string ""]' (9)
      // and trailing '...' inserted before the closing quote (3) + '"]' (2)
      // = 14 characters of wrapping.
      expect(id.length, 44 + 14);
    });

    test('raw source short single line is kept verbatim', () {
      const source = 'print(1)';
      expect(LuaStack.chunkid(source), '[string "print(1)"]');
    });

    test('empty source returns "?"', () {
      expect(LuaStack.chunkid(''), '?');
    });
  });

  group('sourceLine (offending line extraction)', () {
    const src = 'local a = 1\nlocal b = 2\nlocal c = 3\n';

    test('returns the trimmed text of the requested 1-based line', () {
      expect(LuaStack.sourceLine(src, 1), 'local a = 1');
      expect(LuaStack.sourceLine(src, 2), 'local b = 2');
      expect(LuaStack.sourceLine(src, 3), 'local c = 3');
    });

    test('returns null for out-of-range lines', () {
      expect(LuaStack.sourceLine(src, 0), isNull);
      expect(LuaStack.sourceLine(src, 99), isNull);
      expect(LuaStack.sourceLine(src, -1), isNull);
    });

    test('returns null for null/empty source', () {
      expect(LuaStack.sourceLine(null, 1), isNull);
      expect(LuaStack.sourceLine('', 1), isNull);
    });

    test('returns null for `=name` and `@path` sources', () {
      expect(LuaStack.sourceLine('=somechunk', 1), isNull);
      expect(LuaStack.sourceLine('@foo.lua', 1), isNull);
    });

    test('handles a last line with no trailing newline', () {
      expect(LuaStack.sourceLine('one\ntwo\nthree', 3), 'three');
    });

    test('returns null if the requested line is blank', () {
      expect(LuaStack.sourceLine('a\n\nb\n', 2), isNull);
    });
  });

  group('runtime error formatting', () {
    test('loadString: long source does not leak into error prefix', () {
      // Reproduce the original bug: a long script that triggers a runtime
      // error. Before the fix, the error message was prefixed with the
      // entire source. Now it should be `[string "<first line>..."]:<line>`.
      final ls = LuaState.newState();
      ls.openLibs();
      // Sentinel text that appears deep in the script; it must NOT make it
      // into the error prefix after truncation.
      const sentinel = 'SENTINEL_MUST_NOT_APPEAR_IN_ERROR_PREFIX';
      final source = '-- first line that will appear truncated in the id\n'
          '${'-- padding line with $sentinel here\n' * 20}'
          'local t = nil\n'
          'return t.x\n';
      final ok = ls.doString(source);
      expect(ok, isFalse, reason: 'doString should fail on runtime error');
      // `doString` pushes the error message onto the stack on failure.
      final msg = ls.toStr(-1) ?? '';
      expect(msg.contains(sentinel), isFalse,
          reason: 'error message should not embed full source: $msg');
      expect(msg.contains('[string "'), isTrue, reason: msg);
      expect(msg.contains('attempt to index'), isTrue, reason: msg);
      // Error message is now two lines: `[id]:line: msg\n  > <snippet>`.
      // The prefix line is bounded to ~60 chars by chunkid; the snippet
      // line is bounded to ~200 chars.
      expect(msg.length, lessThan(500),
          reason: 'error message unexpectedly long: $msg');
    });

    test('error message includes the offending source line as a snippet', () {
      final ls = LuaState.newState();
      ls.openLibs();
      const source = 'local t = nil\n'
          'return t.x\n';
      final ok = ls.doString(source);
      expect(ok, isFalse);
      final msg = ls.toStr(-1) ?? '';
      // The snippet should be the text of line 2 (where the error happens).
      expect(msg.contains('\n  > return t.x'), isTrue,
          reason: 'expected snippet line, got: $msg');
    });
  });
}
