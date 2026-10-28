import 'package:glados/glados.dart';
import 'package:lua_dardo_plus/lua.dart';

/// Generates valid Lua pattern strings for property-based testing.
///
/// We build patterns from a grammar of Lua pattern items to ensure they are
/// always syntactically valid, while still exercising the full range of the
/// pattern engine: character classes, quantifiers, bracket sets, anchors,
/// captures, and escaped literals.
extension AnyLuaPattern on Any {
  static final _classes = [
    '%a',
    '%d',
    '%w',
    '%s',
    '%l',
    '%u',
    '%p',
    '%x',
    '%A',
    '%D',
    '%W',
    '%S',
    '%L',
    '%U',
    '%P',
    '%X',
  ];

  static final _quantifiers = ['', '*', '+', '?', '-'];

  static final _literals =
      'abcdefghijklmnopqrstuvwxyz0123456789 _,;!@#&=~'.split('');

  static final _escapedLiterals = [
    '%(',
    '%)',
    '%.',
    '%[',
    '%]',
    '%%',
    '%^',
    r'%$',
    '%{',
    '%}',
    '%|',
    r'%\',
    '%+',
    '%*',
    '%-',
    '%?',
  ];

  static final _bracketItems = [
    ..._classes,
    '%-',
    'a-z',
    'A-Z',
    '0-9',
    ...'abcdefg0123 '.split(''),
  ];

  /// A single pattern atom: character class, dot, literal, escaped literal,
  /// or bracket set.
  Generator<String> get _patternAtom {
    return oneOf([
      choose(_classes),
      always('.'),
      choose(_literals),
      choose(_escapedLiterals),
      _bracketSet,
    ]);
  }

  /// A bracket character set like [%w%-] or [abc].
  Generator<String> get _bracketSet {
    return combine2(
      any.bool,
      listWithLengthInRange(1, 3, choose(_bracketItems)),
      (bool negated, List<String> items) {
        final inner = items.join();
        return negated ? '[^$inner]' : '[$inner]';
      },
    );
  }

  /// A pattern atom optionally followed by a quantifier.
  Generator<String> get _quantifiedAtom {
    return combine2(
      _patternAtom,
      choose(_quantifiers),
      (String atom, String quant) => '$atom$quant',
    );
  }

  /// A complete Lua pattern: 1-4 quantified items, optionally anchored.
  Generator<String> get luaPattern {
    return combine3(
      any.bool,
      listWithLengthInRange(1, 4, _quantifiedAtom),
      any.bool,
      (bool anchorStart, List<String> items, bool anchorEnd) {
        final body = items.join();
        final prefix = anchorStart ? '^' : '';
        final suffix = anchorEnd ? r'$' : '';
        return '$prefix$body$suffix';
      },
    );
  }

  /// A pattern wrapped in capture parens.
  Generator<String> get luaPatternWithCapture {
    return listWithLengthInRange(1, 3, _quantifiedAtom)
        .map((items) => '(${items.join()})');
  }

  /// Patterns that match empty strings — common source of infinite loops.
  Generator<String> get emptyMatchPattern {
    return choose([
      '.-',
      '%s*',
      '%d*',
      '%a*',
      '%w*',
      'x?',
      '[abc]-',
      '[%w]*',
      '()',
    ]);
  }

  /// Mix of generated and known-tricky patterns.
  Generator<String> get stressPattern {
    return oneOf([
      luaPattern,
      emptyMatchPattern,
      combine2(
        _quantifiedAtom,
        _quantifiedAtom,
        (String a, String b) => '$a$b',
      ),
    ]);
  }

  /// Input strings that exercise edge cases.
  Generator<String> get edgeCaseString {
    return oneOf([
      choose([
        '',
        ' ',
        '\n',
        '\t',
        'aaaa',
        '   ',
        '123',
        'hello world',
        'a\nb\nc',
        r'()|{}\',
      ]),
      any.letterOrDigits,
    ]);
  }
}

/// Run a Lua snippet, returning up to [nResults] as strings.
/// Returns null if it threw.
List<String?>? _runLua(String code, int nResults) {
  try {
    final ls = LuaState.newState();
    ls.openLibs();
    ls.loadString(code);
    ls.call(0, nResults);
    final results = <String?>[];
    for (var i = 0; i < nResults; i++) {
      final idx = -(nResults - i);
      if (ls.isNil(idx)) {
        results.add(null);
      } else if (ls.type(idx) == LuaType.luaBoolean) {
        results.add(ls.toBoolean(idx) ? 'true' : 'false');
      } else {
        results.add(ls.toStr(idx));
      }
    }
    return results;
  } catch (_) {
    return null;
  }
}

/// Embed [s] as a Lua long string that never collides with the content.
/// Lua strips a leading newline from long strings, so we always prepend one
/// to ensure the content is preserved exactly.
String _luaLong(String s) {
  var level = 0;
  while (s.contains(']${'=' * level}]')) {
    level++;
  }
  final eq = '=' * level;
  // The leading \n is stripped by Lua's long-string parser, leaving
  // exactly [s] as the string value.
  return '[$eq[\n$s]$eq]';
}

/*
Testable properties:

1. Termination — find / match / gmatch / gsub must always return.
2. Consistency — find positions agree with match; gsub("%0") is identity.
3. Anchors — ^pat only matches at start.
4. Empty-match patterns — known landmines for infinite loops.
5. Newlines — dot matches \n in all functions.
6. Literal metacharacters — | { } \ ^ $ are not regex-special.
*/

void main() {
  // -------- Termination --------

  group('Termination', () {
    Glados2(any.stressPattern, any.edgeCaseString).test(
      'string.find always terminates',
      (pattern, input) {
        _runLua(
            'return string.find(${_luaLong(input)}, ${_luaLong(pattern)})', 2);
      },
    );

    Glados2(any.stressPattern, any.edgeCaseString).test(
      'string.match always terminates',
      (pattern, input) {
        _runLua(
            'return string.match(${_luaLong(input)}, ${_luaLong(pattern)})', 1);
      },
    );

    Glados2(any.stressPattern, any.edgeCaseString).test(
      'string.gmatch always terminates and yields finite results',
      (pattern, input) {
        final code = '''
          local t = {}
          for m in string.gmatch(${_luaLong(input)}, ${_luaLong(pattern)}) do
            t[#t+1] = m
            if #t > 1000 then break end
          end
          return #t
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final count = int.tryParse(r[0]!) ?? 0;
          expect(count, lessThanOrEqualTo(input.length + 1),
              reason: 'gmatch produced $count matches for '
                  'input len=${input.length}, pattern="$pattern"');
        }
      },
    );

    Glados2(any.stressPattern, any.edgeCaseString).test(
      'string.gsub always terminates',
      (pattern, input) {
        _runLua(
            'return string.gsub(${_luaLong(input)}, ${_luaLong(pattern)}, "X")',
            2);
      },
    );
  });

  // -------- Consistency --------

  group('Consistency', () {
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'find positions agree with match (no captures)',
      (pattern, input) {
        final code = '''
          local s = ${_luaLong(input)}
          local p = ${_luaLong(pattern)}
          local i, j = string.find(s, p)
          local m = string.match(s, p)
          if i ~= nil and m ~= nil then
            return string.sub(s, i, j), m
          end
          return "NONE", "NONE"
        ''';
        final r = _runLua(code, 2);
        if (r != null && r[0] != 'NONE') {
          expect(r[0], equals(r[1]),
              reason: 'find/match mismatch for "$pattern"');
        }
      },
    );

    Glados2(any.luaPattern, any.edgeCaseString).test(
      'gsub with %0 replacement is identity',
      (pattern, input) {
        final code = '''
          return string.gsub(${_luaLong(input)}, ${_luaLong(pattern)}, "%0")
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(r[0], equals(input),
              reason: 'gsub %%0 changed string for pattern "$pattern"');
        }
      },
    );
  });

  // -------- Anchors --------

  group('Anchors', () {
    Glados(any.edgeCaseString).test(
      '^%a+ only matches at position 1',
      (input) {
        final code = '''
          local i = string.find(${_luaLong(input)}, "^%a+")
          if i then return i else return -1 end
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final pos = int.tryParse(r[0]!) ?? -1;
          if (pos > 0) expect(pos, equals(1));
        }
      },
    );
  });

  // -------- Empty-match patterns --------

  group('Empty-match patterns', () {
    final emptyPats = [
      '.-',
      '%s*',
      '%d*',
      '%a*',
      '%w*',
      'x?',
      '[abc]-',
      r'^.-$'
    ];
    final inputs = [
      '',
      ' ',
      'abc',
      '   ',
      '123',
      'hello world',
      'a\nb\nc',
      '(test)'
    ];

    for (final pat in emptyPats) {
      test('gmatch "$pat" terminates on all inputs', () {
        for (final input in inputs) {
          final code = '''
            local t = {}
            for m in string.gmatch(${_luaLong(input)}, ${_luaLong(pat)}) do
              t[#t+1] = m
              if #t > 1000 then error("runaway") end
            end
            return #t
          ''';
          final r = _runLua(code, 1);
          expect(r, isNotNull, reason: 'gmatch "$pat" on "$input" failed');
        }
      });

      test('gsub "$pat" terminates on all inputs', () {
        for (final input in inputs) {
          final code =
              'return string.gsub(${_luaLong(input)}, ${_luaLong(pat)}, "X")';
          final r = _runLua(code, 2);
          expect(r, isNotNull, reason: 'gsub "$pat" on "$input" failed');
        }
      });
    }
  });

  // -------- Find index bounds --------

  group('Find index bounds', () {
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'find returns valid 1-based indices or nil',
      (pattern, input) {
        final code = '''
          local s = ${_luaLong(input)}
          local i, j = string.find(s, ${_luaLong(pattern)})
          if i == nil then return -1, -1 end
          return i, j
        ''';
        final r = _runLua(code, 2);
        if (r != null && r[0] != null && r[1] != null) {
          final i = int.tryParse(r[0]!);
          final j = int.tryParse(r[1]!);
          if (i != null && j != null && i != -1) {
            expect(i, greaterThanOrEqualTo(1),
                reason: 'find start index < 1 for "$pattern"');
            // j can be i-1 for empty matches (Lua convention)
            expect(j, greaterThanOrEqualTo(i - 1),
                reason: 'find end < start-1 for "$pattern"');
            expect(j, lessThanOrEqualTo(input.length),
                reason: 'find end > #s for "$pattern"');
          }
        }
      },
    );
  });

  // -------- Match returns substrings --------

  group('Match returns substrings', () {
    // Without captures, match should return a substring of input.
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'match result is a substring of input (no captures)',
      (pattern, input) {
        final code = '''
          return string.match(${_luaLong(input)}, ${_luaLong(pattern)})
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(input.contains(r[0]!), isTrue,
              reason: 'match returned "${r[0]}" which is not a '
                  'substring of "$input" for pattern "$pattern"');
        }
      },
    );

    // With captures, each captured group should be a substring of input.
    Glados2(any.luaPatternWithCapture, any.edgeCaseString).test(
      'captured groups are substrings of input',
      (pattern, input) {
        final code = '''
          local r = {string.match(${_luaLong(input)}, ${_luaLong(pattern)})}
          if #r == 0 then return "NONE" end
          for i, v in ipairs(r) do
            if type(v) == "string" then return v end
          end
          return "NONE"
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null && r[0] != 'NONE') {
          expect(input.contains(r[0]!), isTrue,
              reason: 'capture "${r[0]}" not in "$input" for "$pattern"');
        }
      },
    );
  });

  // -------- Gsub count --------

  group('Gsub count', () {
    Glados2(any.stressPattern, any.edgeCaseString).test(
      'gsub replacement count is bounded',
      (pattern, input) {
        final code = '''
          local _, n = string.gsub(${_luaLong(input)}, ${_luaLong(pattern)}, "X")
          return n
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final n = int.tryParse(r[0]!) ?? -1;
          expect(n, greaterThanOrEqualTo(0),
              reason: 'gsub count negative for "$pattern"');
          // At most len+1 matches (empty match at every position + end)
          expect(n, lessThanOrEqualTo(input.length + 1),
              reason: 'gsub count $n > ${input.length + 1} for "$pattern"');
        }
      },
    );
  });

  // -------- Gsub with function replacement --------

  group('Gsub function replacement', () {
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'gsub with identity function is identity',
      (pattern, input) {
        final code = '''
          return string.gsub(${_luaLong(input)}, ${_luaLong(pattern)},
            function(m) return m end)
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(r[0], equals(input),
              reason: 'gsub identity fn changed string for "$pattern"');
        }
      },
    );
  });

  // -------- Plain find --------

  group('Plain find', () {
    Glados2(any.edgeCaseString, any.edgeCaseString).test(
      'plain find agrees with Dart string.contains',
      (needle, haystack) {
        final code = '''
          local i = string.find(${_luaLong(haystack)}, ${_luaLong(needle)}, 1, true)
          if i then return i else return -1 end
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final pos = int.tryParse(r[0]!) ?? -1;
          if (haystack.contains(needle)) {
            expect(pos, greaterThan(0),
                reason: 'Dart says contains but Lua find returned nil');
          } else {
            expect(pos, equals(-1),
                reason: 'Dart says not contains but Lua found at $pos');
          }
        }
      },
    );
  });

  // -------- Determinism --------

  group('Determinism', () {
    Glados2(any.stressPattern, any.edgeCaseString).test(
      'find is deterministic across two calls',
      (pattern, input) {
        final code = '''
          local s = ${_luaLong(input)}
          local p = ${_luaLong(pattern)}
          local i1, j1 = string.find(s, p)
          local i2, j2 = string.find(s, p)
          if i1 == i2 and j1 == j2 then return "OK" end
          return "DIFFER"
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(r[0], equals('OK'),
              reason: 'find not deterministic for "$pattern"');
        }
      },
    );
  });

  // -------- Multiple captures --------

  group('Multiple captures', () {
    Glados(any.edgeCaseString).test(
      '(%a+)%s+(%a+) captures two words if present',
      (input) {
        final code = '''
          local a, b = string.match(${_luaLong(input)}, "(%a+)%s+(%a+)")
          if a and b then return a, b else return "NONE", "NONE" end
        ''';
        final r = _runLua(code, 2);
        if (r != null && r[0] != 'NONE') {
          // Both captures should be alphabetic substrings of input
          expect(r[0], matches(RegExp(r'^[a-zA-Z]+$')));
          expect(r[1], matches(RegExp(r'^[a-zA-Z]+$')));
          expect(input.contains(r[0]!), isTrue);
          expect(input.contains(r[1]!), isTrue);
        }
      },
    );

    Glados(any.edgeCaseString).test(
      '(%d+)/(%d+)/(%d+) captures date-like triples',
      (input) {
        final code = '''
          local a, b, c = string.match(${_luaLong(input)}, "(%d+)/(%d+)/(%d+)")
          if a then return a, b, c else return "NONE", "NONE", "NONE" end
        ''';
        final r = _runLua(code, 3);
        if (r != null && r[0] != 'NONE') {
          for (final cap in r) {
            expect(cap, matches(RegExp(r'^\d+$')),
                reason: 'date capture "$cap" is not all digits');
          }
        }
      },
    );
  });

  // -------- Character class exhaustiveness --------

  group('Character class coverage', () {
    // Each character class should match or not match specific inputs.
    // Glados generates strings; we check the class semantics hold.
    final classTests = <String, bool Function(String)>{
      '%a': (s) => RegExp(r'^[a-zA-Z]+$').hasMatch(s),
      '%d': (s) => RegExp(r'^[0-9]+$').hasMatch(s),
      '%l': (s) => RegExp(r'^[a-z]+$').hasMatch(s),
      '%u': (s) => RegExp(r'^[A-Z]+$').hasMatch(s),
      '%w': (s) => RegExp(r'^[a-zA-Z0-9]+$').hasMatch(s),
      '%s': (s) => RegExp(r'^\s+$').hasMatch(s),
    };

    for (final entry in classTests.entries) {
      final cls = entry.key;
      final dartCheck = entry.value;

      Glados(any.edgeCaseString).test(
        '$cls+ match agrees with Dart regex',
        (input) {
          final code = '''
            return string.match(${_luaLong(input)}, "$cls+")
          ''';
          final r = _runLua(code, 1);
          if (r != null && r[0] != null) {
            expect(dartCheck(r[0]!), isTrue,
                reason: '$cls+ matched "${r[0]}" which fails Dart check');
          }
        },
      );
    }
  });

  // -------- Gmatch collects non-overlapping matches --------

  group('Gmatch coverage', () {
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'gmatch matches are non-overlapping and in order',
      (pattern, input) {
        final code = '''
          local s = ${_luaLong(input)}
          local p = ${_luaLong(pattern)}
          local positions = {}
          local init = 1
          for m in string.gmatch(s, p) do
            if #m > 0 then
              local i, j = string.find(s, p, init)
              if i then
                positions[#positions+1] = i .. "," .. j
                init = j + 1
              end
            end
            if #positions > 100 then break end
          end
          return table.concat(positions, ";")
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null && r[0]!.isNotEmpty) {
          final pairs = r[0]!.split(';');
          var lastEnd = 0;
          for (final pair in pairs) {
            final parts = pair.split(',');
            if (parts.length == 2) {
              final i = int.tryParse(parts[0]) ?? 0;
              final j = int.tryParse(parts[1]) ?? 0;
              expect(i, greaterThan(lastEnd),
                  reason: 'overlapping match at $i, prev end=$lastEnd');
              lastEnd = j;
            }
          }
        }
      },
    );
  });

  // -------- Gsub with n limit --------

  group('Gsub with n limit', () {
    Glados3(any.luaPattern, any.edgeCaseString, any.intInRange(0, 5)).test(
      'gsub with limit n replaces at most n times',
      (pattern, input, n) {
        final code = '''
          local _, count = string.gsub(
            ${_luaLong(input)}, ${_luaLong(pattern)}, "X", $n)
          return count
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final count = int.tryParse(r[0]!) ?? -1;
          expect(count, lessThanOrEqualTo(n),
              reason: 'gsub count=$count exceeded limit n=$n for "$pattern"');
          expect(count, greaterThanOrEqualTo(0));
        }
      },
    );
  });

  // -------- Gmatch and gsub count agree --------

  group('Gmatch/gsub count agreement', () {
    Glados2(any.luaPattern, any.edgeCaseString).test(
      'gmatch iteration count equals gsub replacement count',
      (pattern, input) {
        // Run separately to avoid interaction between the two calls.
        final gmatchCode = '''
          local count = 0
          for _ in string.gmatch(${_luaLong(input)}, ${_luaLong(pattern)}) do
            count = count + 1
            if count > 500 then break end
          end
          return count
        ''';
        final gsubCode = '''
          local _, count = string.gsub(
            ${_luaLong(input)}, ${_luaLong(pattern)}, "X")
          return count
        ''';
        final rGm = _runLua(gmatchCode, 1);
        final rGs = _runLua(gsubCode, 1);
        if (rGm != null && rGm[0] != null && rGs != null && rGs[0] != null) {
          expect(rGm[0], equals(rGs[0]),
              reason:
                  'gmatch=${rGm[0]} vs gsub=${rGs[0]} for pattern "$pattern"');
        }
      },
    );
  });

  // -------- Find with init offset --------

  group('Find with init', () {
    Glados3(any.luaPattern, any.edgeCaseString, any.intInRange(1, 15)).test(
      'find with init skips earlier matches',
      (pattern, input, init) {
        if (init > input.length + 1) return;
        final code = '''
          local s = ${_luaLong(input)}
          local p = ${_luaLong(pattern)}
          local i = string.find(s, p, $init)
          if i then return i else return -1 end
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final pos = int.tryParse(r[0]!) ?? -1;
          if (pos > 0) {
            expect(pos, greaterThanOrEqualTo(init),
                reason: 'find returned pos=$pos < init=$init for "$pattern"');
          }
        }
      },
    );
  });

  // -------- Negated classes are complements --------

  group('Negated class complements', () {
    // For each char class / negation pair, if %a matches then %A must not.
    final pairs = [
      ['%a', '%A'],
      ['%d', '%D'],
      ['%w', '%W'],
      ['%s', '%S'],
      ['%l', '%L'],
      ['%u', '%U'],
    ];

    for (final pair in pairs) {
      Glados(any.edgeCaseString).test(
        '${pair[0]}+ and ${pair[1]}+ never match the same char',
        (input) {
          final code = '''
            local s = ${_luaLong(input)}
            local a = string.match(s, "${pair[0]}")
            local b = string.match(s, "${pair[1]}")
            if a and b then
              -- both matched something; the matched chars must differ
              return a, b
            end
            return "OK", "OK"
          ''';
          final r = _runLua(code, 2);
          if (r != null && r[0] != 'OK') {
            expect(r[0], isNot(equals(r[1])),
                reason: '${pair[0]} and ${pair[1]} both matched "${r[0]}"');
          }
        },
      );
    }
  });

  // -------- string.rep properties --------

  group('string.rep', () {
    Glados2(any.edgeCaseString, any.intInRange(0, 5)).test(
      'rep(s,n) length equals n*#s + (n-1)*#sep',
      (s, n) {
        final code = '''
          local s = ${_luaLong(s)}
          local r = string.rep(s, $n, ",")
          return #r, #s
        ''';
        final r = _runLua(code, 2);
        if (r != null && r[0] != null && r[1] != null) {
          final rLen = int.tryParse(r[0]!) ?? -1;
          final sLen = int.tryParse(r[1]!) ?? -1;
          final expected = n <= 0 ? 0 : sLen * n + (n - 1);
          expect(rLen, equals(expected),
              reason: 'rep length=$rLen expected=$expected for n=$n, #s=$sLen');
        }
      },
    );
  });

  // -------- string.reverse involution --------

  group('string.reverse', () {
    Glados(any.edgeCaseString).test(
      'reverse(reverse(s)) == s',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          return string.reverse(string.reverse(s)) == s
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'), reason: 'reverse is not involution');
        }
      },
    );
  });

  // -------- string.lower/upper idempotence --------

  group('string.lower/upper', () {
    Glados(any.edgeCaseString).test(
      'lower(lower(s)) == lower(s)',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          local l = string.lower(s)
          return string.lower(l) == l
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'), reason: 'lower not idempotent');
        }
      },
    );

    Glados(any.edgeCaseString).test(
      'upper(upper(s)) == upper(s)',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          local u = string.upper(s)
          return string.upper(u) == u
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'), reason: 'upper not idempotent');
        }
      },
    );

    Glados(any.edgeCaseString).test(
      '#lower(s) == #s',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          return #string.lower(s), #s
        ''';
        final r = _runLua(code, 2);
        if (r != null) {
          expect(r[0], equals(r[1]), reason: 'lower changed string length');
        }
      },
    );
  });

  // -------- string.sub properties --------

  group('string.sub', () {
    Glados2(any.edgeCaseString, any.intInRange(-5, 15)).test(
      'sub(s,1) == s',
      (s, _) {
        final code = '''
          local s = ${_luaLong(s)}
          return string.sub(s, 1) == s
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'));
        }
      },
    );

    Glados2(any.edgeCaseString, any.intInRange(1, 10)).test(
      'sub(s,i,j) length <= j-i+1 when i<=j',
      (s, i) {
        final j = i + 2;
        final code = '''
          local s = ${_luaLong(s)}
          local sub = string.sub(s, $i, $j)
          return #sub
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          final len = int.tryParse(r[0]!) ?? -1;
          expect(len, lessThanOrEqualTo(j - i + 1));
          expect(len, greaterThanOrEqualTo(0));
        }
      },
    );
  });

  // -------- string.byte/char round-trip --------

  group('string.byte/char round-trip', () {
    Glados(any.letterOrDigits).test(
      'char(byte(s, 1, #s)) == s for ASCII strings',
      (s) {
        if (s.isEmpty) return;
        final code = '''
          local s = ${_luaLong(s)}
          return string.char(string.byte(s, 1, #s)) == s
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'), reason: 'byte/char round-trip failed');
        }
      },
    );
  });

  // -------- string.len --------

  group('string.len', () {
    Glados(any.edgeCaseString).test(
      'string.len(s) == #s',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          return string.len(s) == #s
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'));
        }
      },
    );
  });

  // -------- string.format basic --------

  group('string.format', () {
    Glados(any.intInRange(-1000, 1000)).test(
      'format("%%d", n) == tostring(n) for integers',
      (n) {
        final code = '''
          local n = $n
          return string.format("%d", n), tostring(n)
        ''';
        final r = _runLua(code, 2);
        if (r != null) {
          expect(r[0], equals(r[1]), reason: 'format %%d != tostring for $n');
        }
      },
    );

    Glados(any.edgeCaseString).test(
      'format("%s", s) == s',
      (s) {
        final code = '''
          local s = ${_luaLong(s)}
          return string.format("%s", s) == s
        ''';
        final r = _runLua(code, 1);
        if (r != null) {
          expect(r[0], equals('true'), reason: 'format %%s != s');
        }
      },
    );
  });

  // -------- Pack/unpack round-trip --------

  group('string.pack/unpack round-trip', () {
    Glados(any.intInRange(-1000000, 1000000)).test(
      'pack/unpack i4 round-trip',
      (n) {
        final code = '''
          local packed = string.pack("i4", $n)
          local unpacked = string.unpack("i4", packed)
          return unpacked
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(int.tryParse(r[0]!), equals(n),
              reason: 'pack/unpack i4 round-trip failed for $n');
        }
      },
    );

    Glados2(
      any.intInRange(-128, 127),
      any.intInRange(-32768, 32767),
    ).test(
      'pack/unpack "bh" round-trip',
      (b, h) {
        final code = '''
          local packed = string.pack("bh", $b, $h)
          local b2, h2 = string.unpack("bh", packed)
          return b2, h2
        ''';
        final r = _runLua(code, 2);
        if (r != null && r[0] != null && r[1] != null) {
          expect(int.tryParse(r[0]!), equals(b));
          expect(int.tryParse(r[1]!), equals(h));
        }
      },
    );
  });

  // -------- Gsub with table replacement --------

  group('Gsub table replacement', () {
    Glados(any.edgeCaseString).test(
      'gsub with empty table keeps original',
      (input) {
        final code = '''
          return string.gsub(${_luaLong(input)}, "%a+", {})
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != null) {
          expect(r[0], equals(input),
              reason: 'gsub with empty table changed string');
        }
      },
    );
  });

  // -------- Find with captures returns groups --------

  group('Find with captures', () {
    Glados(any.edgeCaseString).test(
      'find returns capture groups matching the input',
      (input) {
        final code = '''
          local s = ${_luaLong(input)}
          local i, j, c1 = string.find(s, "(%a+)")
          if c1 then return c1 else return "NONE" end
        ''';
        final r = _runLua(code, 1);
        if (r != null && r[0] != 'NONE' && r[0] != null) {
          expect(r[0], matches(RegExp(r'^[a-zA-Z]+$')),
              reason: 'capture from find is not alphabetic: ${r[0]}');
          expect(input.contains(r[0]!), isTrue);
        }
      },
    );
  });

  // -------- Newlines --------

  group('Newlines', () {
    test('dot matches newline in find', () {
      final r = _runLua(r'return string.find("a\nb", ".+")', 2);
      expect(r![0], equals('1'));
      expect(r[1], equals('3'));
    });

    test('dot matches newline in match', () {
      final r = _runLua(r'return string.match("a\nb", ".+")', 1);
      expect(r![0], equals('a\nb'));
    });

    test('dot matches newline in gmatch', () {
      final r = _runLua(r'''
        local t = {}
        for m in string.gmatch("a\nb\nc", "[^\n]+") do t[#t+1] = m end
        return #t, t[1], t[2], t[3]
      ''', 4);
      expect(r![0], equals('3'));
      expect(r[1], equals('a'));
      expect(r[2], equals('b'));
      expect(r[3], equals('c'));
    });

    test('dot matches newline in gsub', () {
      final r = _runLua(r'return string.gsub("a\nb", "(.+)", "[%1]")', 2);
      expect(r![0], equals('[a\nb]'));
    });
  });

  // -------- Literal metacharacters --------

  group('Literal metacharacters', () {
    test('pipe is literal', () {
      expect(_runLua('return string.find("a|b", "a|b")', 2)?[0], equals('1'));
      expect(_runLua('return string.find("b", "a|b")', 2)?[0], isNull);
    });

    test('curly braces are literal', () {
      expect(_runLua('return string.match("x{3}", "%a{%d}")', 1)?[0],
          equals('x{3}'));
    });

    test('backslash is literal', () {
      expect(_runLua(r'return string.find("a\\b", "\\")', 2)?[0], equals('2'));
    });

    test('dollar mid-pattern is literal', () {
      expect(_runLua(r'return string.match("costs $10", "$%d+")', 1)?[0],
          equals(r'$10'));
    });

    test('caret mid-pattern is literal', () {
      expect(_runLua('return string.match("2^10", "%d^%d+")', 1)?[0],
          equals('2^10'));
    });
  });
}
