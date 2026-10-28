import 'package:lua_dardo_plus/lua.dart';
import 'package:test/test.dart';

bool testString() {
  try {
    LuaState state = LuaState.newState();
    state.openLibs();
    state.loadString(r'''
--[[
multi-line comments
multi-line comments
]]

a = [[abc
123]]
b = [==[
abc
123]==]
print(a)
print(b)
str = 'a string with "quotes" and \n new line\r\n'
print(str)
print(string.gsub("hello world", "(%w+)", "%1 %1"))
print(string.len("abc"))
print(string.byte("abcABC", 1, 6))
print(string.char(97, 98, 99))
print(string.upper("acde"))
print(string.find("8Abc%a23", "%a"))
print(string.find("8Abc%a23", "(%a)"))
print(string.find("8Abc%a23", "(%a)", 4))
print(string.find("8Abc%a23", "%a", 1, true))
print(string.find("8Abca23", "Ab"))
print(string.match("abc123ABC456", "ABC"))
''');
    state.pCall(0, 0, 1);
  } catch (e, s) {
    print('$e\n$s');
    return false;
  }
  return true;
}

void main() {
  test('string.reverse reverses a multi-char string', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.reverse("hello")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('olleh'));
  });

  test('string.reverse handles single char', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.reverse("a")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('a'));
  });

  test('string.reverse handles empty string', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.reverse("")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals(''));
  });

  test('string.find end pos: pattern length != match length', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("ab12cd", "%d%d")');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(3));
    expect(ls.toInteger(-1), equals(4));
  });

  test('string.find returns correct end position with pattern', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("abc123def", "%d+")');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(4));
    expect(ls.toInteger(-1), equals(6));
  });

  test('string.find returns correct end position with plain search', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("hello world", "world", 1, true)');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(7));
    expect(ls.toInteger(-1), equals(11));
  });

  test('string.find returns capture groups', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("2026-02-27", "(%d+)-(%d+)-(%d+)")');
    ls.call(0, 5);
    expect(ls.toInteger(-5), equals(1)); // start
    expect(ls.toInteger(-4), equals(10)); // end
    expect(ls.toStr(-3), equals('2026'));
    expect(ls.toStr(-2), equals('02'));
    expect(ls.toStr(-1), equals('27'));
  });

  test('string.format %e', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.format("%e", 314.0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), contains('14'));
  });

  test('string.format %g', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.format("%g", 3.14)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('3.14'));
  });

  test('string.format %E', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.format("%E", 314.0)');
    ls.call(0, 1);
    expect(ls.toStr(-1), contains('14'));
  });

  test('string.format %G', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.format("%G", 3.14)');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('3.14'));
  });

  test('string.gmatch basic iteration', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local result = {}
      for w in string.gmatch("hello world foo", "%a+") do
        result[#result + 1] = w
      end
      return result[1], result[2], result[3]
    ''');
    ls.call(0, 3);
    expect(ls.toStr(-3), equals('hello'));
    expect(ls.toStr(-2), equals('world'));
    expect(ls.toStr(-1), equals('foo'));
  });

  test('string.gmatch with captures', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local keys = {}
      local vals = {}
      for k, v in string.gmatch("a=1, b=2, c=3", "(%a)=(%d)") do
        keys[#keys + 1] = k
        vals[#vals + 1] = v
      end
      return keys[1], vals[1], keys[2], vals[2], keys[3], vals[3]
    ''');
    ls.call(0, 6);
    expect(ls.toStr(-6), equals('a'));
    expect(ls.toStr(-5), equals('1'));
    expect(ls.toStr(-4), equals('b'));
    expect(ls.toStr(-3), equals('2'));
    expect(ls.toStr(-2), equals('c'));
    expect(ls.toStr(-1), equals('3'));
  });

  test('string.gmatch capture text appears before match', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local result = {}
      for w in string.gmatch("1a1", "a(%d)") do
        result[#result + 1] = w
      end
      return #result, result[1]
    ''');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(1));
    expect(ls.toStr(-1), equals('1'));
  });

  test('string.gmatch no infinite loop on empty match', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local count = 0
      for w in string.gmatch("abc", ".-") do
        count = count + 1
        if count > 10 then break end
      end
      return count
    ''');
    ls.call(0, 1);
    expect(ls.toInteger(-1), lessThan(11));
  });

  test('string.gsub with capture back-references', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.gsub("hello", "(h)", "%1%1")');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('hhello'));
  });

  test('string.gsub with multiple capture back-references', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.gsub("abc", "(a)(b)", "%2%1")');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('bac'));
  });

  test('string.find empty pattern', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("hello", "", 1, true)');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(1));
    expect(ls.toInteger(-1), equals(0));
  });

  test('string.find empty pattern with init > 1', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("hello", "", 3, true)');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(3));
    expect(ls.toInteger(-1), equals(2));
  });

  test('string.find plain with init > 1', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("hello world", "world", 5, true)');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(7));
    expect(ls.toInteger(-1), equals(11));
  });

  test('string.format %q basic', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.format("%q", "hello world")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('"hello world"'));
  });

  test('string.format %q escapes special chars', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      return string.format("%q", 'he said "hi"')
    ''');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, contains(r'\"'));
    expect(result.startsWith('"'), isTrue);
    expect(result.endsWith('"'), isTrue);
  });

  test('string.format %q escapes backslash and newline', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      return string.format("%q", "line1\nline2\\end")
    ''');
    ls.call(0, 1);
    var result = ls.toStr(-1)!;
    expect(result, contains(r'\n'));
    expect(result, contains(r'\\'));
  });

  test('string.gsub with function replacement', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      return string.gsub("hello world", "%w+", function(w)
        return w:upper()
      end)
    ''');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('HELLO WORLD'));
    expect(ls.toInteger(-1), equals(2));
  });

  test('string.gsub with table replacement', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local t = {hello="HI", world="EARTH"}
      return string.gsub("hello world", "%w+", t)
    ''');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('HI EARTH'));
    expect(ls.toInteger(-1), equals(2));
  });

  test('string.gsub function returns nil keeps match', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      return string.gsub("abc", "(%w)", function(w)
        if w == "b" then return w:upper() end
      end)
    ''');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('aBc'));
  });

  test('string.gsub %0 refers to whole match', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.gsub("hello", "(%w+)", "[%0]")');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('[hello]'));
  });

  test('hex float literal with negative exponent', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return 0x1p-3');
    ls.call(0, 1);
    expect(ls.toNumber(-1), equals(0.125));
  });

  test('float literal with negative exponent', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return 1e-2');
    ls.call(0, 1);
    expect(ls.toNumber(-1), equals(0.01));
  });

  test('hex float with large exponent', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 0x1p100 should not crash; = 2^100
    ls.loadString(r'return 0x1p100');
    ls.call(0, 1);
    expect(ls.toNumber(-1), equals(1.2676506002282294e+30));
  });

  test('hex float with large negative exponent', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // 0x1p-100 should not crash
    ls.loadString(r'return 0x1p-100');
    ls.call(0, 1);
    expect(ls.toNumber(-1), closeTo(7.888609052210118e-31, 1e-40));
  });

  test('hex float with positive exponent', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return 0x1p4');
    ls.call(0, 1);
    expect(ls.toNumber(-1), equals(16.0));
  });

  test('string.pack and unpack integers', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local s = string.pack("<i4i4", 1, 2)
      local a, b = string.unpack("<i4i4", s)
      return a, b
    ''');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(1));
    expect(ls.toInteger(-1), equals(2));
  });

  test('string.pack and unpack byte and double', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local s = string.pack("Bd", 255, 3.14)
      local a, b = string.unpack("Bd", s)
      return a, b
    ''');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(255));
    expect(ls.toNumber(-1), closeTo(3.14, 0.0001));
  });

  test('string.pack and unpack string with length prefix', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local s = string.pack("s4", "hello")
      local result = string.unpack("s4", s)
      return result
    ''');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('hello'));
  });

  test('string.pack and unpack zero-terminated string', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local s = string.pack("z", "hello")
      local result = string.unpack("z", s)
      return result
    ''');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('hello'));
  });

  test('string.packsize', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      return string.packsize("i4i4"), string.packsize("Bd"), string.packsize("j")
    ''');
    ls.call(0, 3);
    expect(ls.toInteger(-3), equals(8));
    expect(ls.toInteger(-2), equals(9));
    expect(ls.toInteger(-1), equals(8));
  });

  test('string.dump and load roundtrip', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local function add(a, b) return a + b end
      local dumped = string.dump(add)
      local restored = load(dumped)
      return restored(3, 4)
    ''');
    ls.call(0, 1);
    expect(ls.toInteger(-1), equals(7));
  });

  test('string.dump with strip option', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local function mul(a, b) return a * b end
      local dumped = string.dump(mul, true)
      local restored = load(dumped)
      return restored(5, 6)
    ''');
    ls.call(0, 1);
    expect(ls.toInteger(-1), equals(30));
  });

  test('string.pack big endian', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local s = string.pack(">i2", 256)
      local a, b = string.byte(s, 1, 2)
      return a, b
    ''');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(1)); // high byte
    expect(ls.toInteger(-1), equals(0)); // low byte
  });

  // ---- Bug fixes: luaPatternToRegex correctness ----

  // Bug 1: dot should match newline (Lua . matches ANY char including \n)
  test('pattern . matches newline', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("ab\ncd", "(.+)")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('ab\ncd'));
  });

  test('pattern . matches newline in find', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.find("ab\ncd", ".+")');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(1));
    expect(ls.toInteger(-1), equals(5));
  });

  // Bug 2: backslash is literal in Lua patterns, not a regex escape
  test('backslash is literal in pattern', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // In Lua source, "\\" is one backslash char.
    // The string is "hello\world" (with literal backslash).
    // Pattern "\\" matches a single literal backslash.
    ls.loadString(r'''
      local s = "hello\\world"
      return string.find(s, "\\")
    ''');
    ls.call(0, 2);
    expect(ls.toInteger(-2), equals(6));
    expect(ls.toInteger(-1), equals(6));
  });

  // Bug 3: pipe | is literal in Lua patterns, not alternation
  test('pipe is literal in pattern', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("a|b", "a|b")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('a|b'));
  });

  test('pipe is literal - no alternation', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("b", "a|b")');
    ls.call(0, 1);
    // Lua: "a|b" is a literal 3-char pattern, won't match "b" alone
    expect(ls.isNil(-1), isTrue);
  });

  // Bug 4: curly braces are literal in Lua patterns
  test('curly braces are literal in pattern', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("x{3}", "%a{%d}")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('x{3}'));
  });

  test('curly braces do not act as quantifiers', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // In Lua, "%d{3}" means: digit, then literal {3}
    // It should NOT match "123" (which regex \d{3} would)
    ls.loadString(r'return string.match("5{3}", "%d{3}")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('5{3}'));
  });

  // Bug 5: ^ mid-pattern is literal
  test('caret mid-pattern is literal', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("2^10", "%d^%d+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('2^10'));
  });

  test('caret at start is still an anchor', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("abc", "^%a+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('abc'));
  });

  // Bug 6: $ mid-pattern is literal
  test('dollar mid-pattern is literal', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("costs $10", "$%d+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\$10'));
  });

  test('dollar at end is still an anchor', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("abc", "%a+$")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('abc'));
  });

  // Bug 7: lazy quantifier after %-escaped chars whose literal is in exclusion set
  test('lazy quantifier after escaped paren', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // %(- means: match 0 or more literal ( lazily, then %) is literal )
    // "()" should match: %(- matches empty, %) matches )
    // Actually %(- matches zero (s, then %) matches )
    // The full match on "()" is "()"
    ls.loadString(r'return string.match("()", "%(-%)")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('()'));
  });

  test('lazy quantifier after escaped star', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    // %*- means: 0 or more literal * lazily
    // "%*-x" on "***x" should match "***x" (must consume *s to reach x)
    ls.loadString(r'return string.match("***x", "%*-x")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('***x'));
  });

  // ---- Character classes inside bracket sets [%w], [%a%-], etc. ----

  test('pattern [%w]+ matches word chars', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("hello42world", "[%w]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('hello42world'));
  });

  test('pattern [%a]+ matches only letters', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("abc123", "[%a]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('abc'));
  });

  test('pattern [%d]+ matches only digits', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("abc123", "[%d]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('123'));
  });

  test('pattern [%w%-]+ matches word chars and hyphens', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("my-slug-42", "[%w%-]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('my-slug-42'));
  });

  test('pattern [%a%-]+ matches letters and hyphens', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("foo-bar-baz", "[%a%-]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('foo-bar-baz'));
  });

  test('pattern [%a%d]+ matches letters and digits', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("a1b2c3!!", "[%a%d]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('a1b2c3'));
  });

  test('pattern [%s%d]+ matches whitespace and digits', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("abc 123", "[%s%d]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals(' 123'));
  });

  test('pattern [%w%-]+ in gmatch iterates hyphenated tokens', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'''
      local result = {}
      for w in string.gmatch("one-two three-four", "[%w%-]+") do
        result[#result + 1] = w
      end
      return result[1], result[2]
    ''');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('one-two'));
    expect(ls.toStr(-1), equals('three-four'));
  });

  test('pattern [%w%-]+ in gsub replaces hyphenated words', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.gsub("my-var", "[%w%-]+", "X")');
    ls.call(0, 2);
    expect(ls.toStr(-2), equals('X'));
    expect(ls.toInteger(-1), equals(1));
  });

  test('pattern [%w%.%-]+ matches URL-path-like strings', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("example.com/my-page", "[%w%.%-]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('example.com'));
  });

  test('pattern [%l%u]+ is equivalent to [%a]+', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return string.match("Hello123", "[%l%u]+")');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('Hello'));
  });

  test('lua table standard library test', () {
    expect(testString(), true);
  });

  // ── \xXX / \ddd UTF-8 byte-escape decoding ──────────────────────────

  test('\\xc2\\xb7 decodes to U+00B7 middle dot', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\xc2\xb7"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u00B7'));
  });

  test('\\xc3\\xa9 decodes to U+00E9 (é)', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "caf\xc3\xa9"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('café'));
  });

  test('\\xe2\\x80\\x94 decodes to U+2014 em dash', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\xe2\x80\x94"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u2014'));
  });

  test('\\xf0\\x9f\\x98\\x80 decodes to U+1F600 (😀)', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\xf0\x9f\x98\x80"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u{1F600}'));
  });

  test('\\ddd decimal escapes decode as UTF-8', () {
    // \194\183 is \xc2\xb7 in decimal = U+00B7
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\194\183"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u00B7'));
  });

  test('mixed \\xXX and plain ASCII', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "A\xc2\xb7B"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('A\u00B7B'));
  });

  test('consecutive multi-byte sequences', () {
    // Two middle dots back-to-back
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\xc2\xb7\xc2\xb7"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u00B7\u00B7'));
  });

  test('single ASCII \\xXX stays unchanged', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\x41"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('A'));
  });

  test('\\u{B7} still produces U+00B7 directly', () {
    LuaState ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(r'return "\u{B7}"');
    ls.call(0, 1);
    expect(ls.toStr(-1), equals('\u00B7'));
  });
}
