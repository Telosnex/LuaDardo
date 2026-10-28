import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/src/stdlib/lua_pattern.dart';
import 'package:test/test.dart';

/// Exercises features that the previous RegExp-based pattern translator
/// either silently mishandled (`%b`, `%f`, position captures) or handled in
/// regex-specific ways that diverge from reference Lua 5.3 semantics.
void main() {
  group('LuaPattern.match basics', () {
    test('literal', () {
      final m = LuaPattern.match('hello world', 'world');
      expect(m, isNotNull);
      expect(m!.start, 6);
      expect(m.end, 11);
    });

    test('capture', () {
      final m = LuaPattern.match('hello 42', '(%a+) (%d+)');
      expect(m!.captures.length, 2);
      expect((m.captures[0] as StringCapture).value, 'hello');
      expect((m.captures[1] as StringCapture).value, '42');
    });

    test('no match returns null', () {
      expect(LuaPattern.match('abc', r'\d+'), isNull);
    });

    test('anchored ^ only tries at init', () {
      expect(LuaPattern.match('foobar', '^bar'), isNull);
      expect(LuaPattern.match('bar', '^bar'), isNotNull);
    });

    test('anchored \$ requires match to end at string end', () {
      expect(LuaPattern.match('foo bar', 'foo\$'), isNull);
      expect(LuaPattern.match('foo', 'foo\$'), isNotNull);
    });
  });

  group('%b balanced match (the main bug)', () {
    test('extracts outermost {...}', () {
      final m = LuaPattern.match('prefix {a, b, c} suffix', '(%b{})');
      expect(m, isNotNull);
      expect((m!.captures[0] as StringCapture).value, '{a, b, c}');
    });

    test('handles nested braces correctly', () {
      final m = LuaPattern.match('{a, {b, c}, {d}}', '%b{}');
      expect(m, isNotNull);
      expect(m!.end - m.start, '{a, {b, c}, {d}}'.length);
    });

    test('handles JSON-ish body', () {
      const body = 'garbage {"results":{"sunrise":"06:42"},"status":"OK"} more';
      final m = LuaPattern.match(body, '(%b{})');
      expect(m, isNotNull);
      expect((m!.captures[0] as StringCapture).value,
          '{"results":{"sunrise":"06:42"},"status":"OK"}');
    });

    test('%b() parenthesis balance', () {
      final m = LuaPattern.match('f(x, g(y, z), w)', '%b()');
      expect(m, isNotNull);
      expect(m!.end - m.start, '(x, g(y, z), w)'.length);
    });

    test('%b[] bracket balance', () {
      final m = LuaPattern.match('arr[a[0][1]][2]', '%b[]');
      expect(m, isNotNull);
      expect(m!.end - m.start, '[a[0][1]]'.length);
    });

    test('unclosed returns null', () {
      expect(LuaPattern.match('{a, b, c', '%b{}'), isNull);
    });

    test("malformed %b without args throws", () {
      expect(
          () => LuaPattern.match('x', '%b{'), throwsA(isA<LuaPatternError>()));
    });

    test('integrates with string.match via VM', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString(r'return string.match("hello {foo} world", "(%b{})")'),
          isTrue);
      expect(ls.toStr(-1), '{foo}');
    });

    test('integrates with string.gsub via VM', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString(r'''
            local count
            local r, c = string.gsub("a{1}b{2}c{3}", "%b{}", "X")
            return r, c
          '''), isTrue);
      expect(ls.toStr(-2), 'aXbXcX');
      expect(ls.toInteger(-1), 3);
    });
  });

  group('%f frontier pattern', () {
    test('matches transition into letter class', () {
      // Find each word-initial position.
      final matches =
          LuaPattern.allMatches('hello, world!', '%f[%a]%a+').toList();
      expect(matches.length, 2);
      expect(
          'hello, world!'.substring(matches[0].start, matches[0].end), 'hello');
      expect(
          'hello, world!'.substring(matches[1].start, matches[1].end), 'world');
    });

    test('treats start-of-string boundary as non-class', () {
      // '%f[%a]' at position 0 should match if string[0] is a letter.
      final m = LuaPattern.match('abc def', '%f[%a]%a+');
      expect(m, isNotNull);
      expect(m!.start, 0);
      expect(m.end, 3);
    });

    test('integrates with string.gmatch via VM', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString(r'''
            local result = {}
            for w in string.gmatch("abc 123 def", "%f[%a]%a+") do
              table.insert(result, w)
            end
            return table.concat(result, ",")
          '''), isTrue);
      expect(ls.toStr(-1), 'abc,def');
    });

    test('requires [ after %f', () {
      expect(
          () => LuaPattern.match('x', '%fx'), throwsA(isA<LuaPatternError>()));
    });
  });

  group('position captures ()', () {
    test('empty capture returns 1-based position', () {
      final m = LuaPattern.match('hello world', '()world()');
      expect(m, isNotNull);
      expect(m!.captures.length, 2);
      expect((m.captures[0] as PositionCapture).position, 7); // 1-based
      expect((m.captures[1] as PositionCapture).position, 12);
    });

    test('integrates with string.match: returns integers', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString('return string.match("abcXdef", "()X()")'), isTrue);
      expect(ls.toInteger(-1), 5);
      expect(ls.toInteger(-2), 4);
    });
  });

  group('back-references %N', () {
    test('matches repeated capture', () {
      final m = LuaPattern.match('abcabc', '(abc)%1');
      expect(m, isNotNull);
      expect(m!.end, 6);
      expect((m.captures[0] as StringCapture).value, 'abc');
    });

    test('fails when repeat differs', () {
      expect(LuaPattern.match('abcxyz', '(abc)%1'), isNull);
    });

    test('integrates with string.find via VM', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString(r'return string.find("xyzxyz", "(xyz)%1")'), isTrue);
      // Stack (top first): capture1, end, start.
      expect(ls.toStr(-1), 'xyz');
      expect(ls.toInteger(-2), 6);
      expect(ls.toInteger(-3), 1);
    });
  });

  group('greedy vs lazy quantifiers', () {
    test('* is greedy', () {
      final m = LuaPattern.match('<a><b>', '<.*>');
      expect(m, isNotNull);
      expect(m!.end - m.start, '<a><b>'.length);
    });

    test('- is lazy', () {
      final m = LuaPattern.match('<a><b>', '<.->');
      expect(m, isNotNull);
      expect(m!.end - m.start, '<a>'.length);
    });
  });

  group('character classes', () {
    // Reference Lua uses ASCII-only ctype semantics.
    test('%s matches only ASCII whitespace', () {
      final m = LuaPattern.match('a\u00a0b', '%s'); // non-breaking space
      expect(m, isNull,
          reason: '\\u00a0 is not ASCII whitespace per reference Lua');
    });

    test('%w matches only ASCII alnum', () {
      expect(LuaPattern.match('a', '%w'), isNotNull);
      expect(LuaPattern.match('1', '%w'), isNotNull);
      expect(LuaPattern.match('\u00e9', '%w'), isNull,
          reason: 'é is not ASCII alnum');
    });

    test('uppercase class letters negate', () {
      expect(LuaPattern.match('x', '%A'), isNull); // letter → %A fails
      expect(LuaPattern.match('1', '%A'), isNotNull);
    });

    test('bracket range a-z', () {
      expect(LuaPattern.match('M', '[a-z]'), isNull);
      expect(LuaPattern.match('m', '[a-z]'), isNotNull);
    });

    test('bracket negation ^', () {
      final m = LuaPattern.match('abc123', '[^%a]+');
      expect(m, isNotNull);
      expect('abc123'.substring(m!.start, m.end), '123');
    });
  });

  group('malformed patterns', () {
    test("ending with '%' throws when matcher reaches it", () {
      // Reference Lua only reports malformed patterns lazily, when the
      // offending item is actually encountered during matching. A pattern
      // whose prefix doesn't match never reaches the trailing '%'.
      expect(() => LuaPattern.match('foo', 'foo%'),
          throwsA(isA<LuaPatternError>()));
    });

    test("unclosed bracket throws", () {
      expect(
          () => LuaPattern.match('x', '[abc'), throwsA(isA<LuaPatternError>()));
    });
  });

  group('gsub with string replacement', () {
    test('%% becomes literal %', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(ls.doString(r'return (string.gsub("x", "x", "100%%"))'), isTrue);
      expect(ls.toStr(-1), '100%');
    });

    test('%0 refers to whole match', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(
          ls.doString(r'return (string.gsub("hello", "%a+", "<%0>"))'), isTrue);
      expect(ls.toStr(-1), '<hello>');
    });

    test('%1 refers to first capture', () {
      final ls = LuaState.newState();
      ls.openLibs();
      expect(
          ls.doString(
              r'return (string.gsub("hello world", "(%w+) (%w+)", "%2 %1"))'),
          isTrue);
      expect(ls.toStr(-1), 'world hello');
    });
  });
}
