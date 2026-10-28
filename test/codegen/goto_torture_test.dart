import 'package:lua_dardo_plus/lua.dart';
import 'package:test/test.dart';

/// Helper: run Lua code, return single result
dynamic luaEval(String code) {
  LuaState ls = LuaState.newState();
  ls.openLibs();
  ls.loadString(code);
  ls.call(0, 1);
  if (ls.isInteger(-1)) return ls.toInteger(-1);
  if (ls.isNumber(-1)) return ls.toNumber(-1);
  if (ls.isString(-1)) return ls.toStr(-1);
  if (ls.isBoolean(-1)) return ls.toBoolean(-1);
  if (ls.isNil(-1)) return null;
  return '<unknown>';
}

/// Helper: run Lua code, expect compile error containing message
void expectCompileError(String code, String containsMsg) {
  expect(
    () {
      LuaState ls = LuaState.newState();
      ls.openLibs();
      ls.loadString(code);
    },
    throwsA(isA<Exception>().having(
      (e) => e.toString(),
      'message',
      contains(containsMsg),
    )),
  );
}

void main() {
  group('goto torture:', () {
    // ================================================================
    // BASIC CORRECTNESS
    // ================================================================

    test('label at very start of chunk (before any code)', () {
      // label.pc could be -1 if no instructions emitted yet
      expect(luaEval(r'''
        ::start::
        return 42
      '''), equals(42));
    });

    test('backward goto to label at chunk start', () {
      expect(luaEval(r'''
        local i = 0
        ::start::
        i = i + 1
        if i < 3 then goto start end
        return i
      '''), equals(3));
    });

    test('adjacent labels share same target', () {
      expect(luaEval(r'''
        goto b
        ::a:: ::b::
        return 99
      '''), equals(99));
    });

    test('goto to label immediately following', () {
      // goto should be a no-op
      expect(luaEval(r'''
        local x = 1
        goto next
        ::next::
        x = x + 1
        return x
      '''), equals(2));
    });

    test('multiple forward gotos to same label', () {
      expect(luaEval(r'''
        local x = 0
        if true then
          x = x + 1
          goto done
        end
        if true then
          x = x + 100
          goto done
        end
        ::done::
        return x
      '''), equals(1));
    });

    test('goto as very last statement before implicit return', () {
      expect(luaEval(r'''
        local x = 0
        ::loop::
        x = x + 1
        if x >= 5 then goto done end
        goto loop
        ::done::
        return x
      '''), equals(5));
    });

    // ================================================================
    // SCOPE INTERACTIONS
    // ================================================================

    test('goto out of deeply nested blocks (5 levels)', () {
      expect(luaEval(r'''
        local r = "start"
        do do do do do
          r = r .. "-deep"
          goto out
        end end end end end
        r = r .. "-skipped"
        ::out::
        return r
      '''), equals("start-deep"));
    });

    test('goto between if branches — forward jump over else', () {
      expect(luaEval(r'''
        local x = 0
        if false then
          x = 1
        else
          goto skip
          x = 2
        end
        ::skip::
        return x
      '''), equals(0));
    });

    test('goto in for loop to label after loop', () {
      expect(luaEval(r'''
        local sum = 0
        for i = 1, 100 do
          if i > 5 then goto done end
          sum = sum + i
        end
        ::done::
        return sum
      '''), equals(15));
    });

    test('goto in while loop to label after loop', () {
      expect(luaEval(r'''
        local i = 0
        local sum = 0
        while i < 100 do
          i = i + 1
          if i > 5 then goto done end
          sum = sum + i
        end
        ::done::
        return sum
      '''), equals(15));
    });

    test('goto in repeat loop to label after loop', () {
      expect(luaEval(r'''
        local i = 0
        local sum = 0
        repeat
          i = i + 1
          if i > 5 then goto done end
          sum = sum + i
        until false
        ::done::
        return sum
      '''), equals(15));
    });

    test('goto inside nested for loops — break out of both', () {
      expect(luaEval(r'''
        local result = ""
        for i = 1, 10 do
          for j = 1, 10 do
            if i == 2 and j == 3 then goto done end
            result = result .. i .. "," .. j .. " "
          end
        end
        ::done::
        return result
      '''), equals("1,1 1,2 1,3 1,4 1,5 1,6 1,7 1,8 1,9 1,10 2,1 2,2 "));
    });

    // ================================================================
    // UPVALUE CLOSING — the big one
    // ================================================================

    test('goto out of scope with captured upvalue', () {
      // When goto jumps out of a do-end block that has a local
      // captured as an upvalue, the upvalue must be properly closed.
      expect(luaEval(r'''
        local f
        do
          local x = 42
          f = function() return x end
          goto done
        end
        ::done::
        return f()
      '''), equals(42));
    });

    test('goto out of scope — upvalue sees last assigned value', () {
      expect(luaEval(r'''
        local f
        do
          local x = 1
          x = 2
          f = function() return x end
          x = 3
          goto done
          x = 999  -- should be skipped
        end
        ::done::
        return f()
      '''), equals(3));
    });

    test('backward goto loop with upvalue capture each iteration', () {
      // Each iteration captures a different value
      expect(luaEval(r'''
        local funcs = {}
        local i = 0
        ::loop::
        i = i + 1
        do
          local v = i
          funcs[i] = function() return v end
        end
        if i < 3 then goto loop end
        return funcs[1]() * 100 + funcs[2]() * 10 + funcs[3]()
      '''), equals(123));
    });

    // ================================================================
    // SAME-NAME LABELS IN DIFFERENT SCOPES
    // ================================================================

    test('same label name in sibling do-end blocks', () {
      expect(luaEval(r'''
        local x = 0
        do
          x = x + 1
          goto done
          x = x + 100
          ::done::
        end
        do
          x = x + 10
          goto done
          x = x + 1000
          ::done::
        end
        return x
      '''), equals(11));
    });

    test('same label name reused after block exit', () {
      // After a do-end block with ::x::, a new ::x:: at the same scope is OK
      expect(luaEval(r'''
        local r = 0
        do
          ::x::
          r = r + 1
          if r < 2 then goto x end
        end
        -- The inner ::x:: is now gone from scope
        -- Define a new ::x:: at outer scope
        goto x
        r = r + 100
        ::x::
        return r
      '''), equals(2));
    });

    test('outer label still visible after inner same-name label exits scope',
        () {
      // This is the tricky one: inner ::x:: shadows outer ::x::,
      // but after inner scope ends, outer ::x:: should be visible again
      expect(luaEval(r'''
        local r = ""
        ::x::
        r = r .. "A"
        if #r < 3 then
          do
            -- inner scope has its own ::x::
            goto x  -- should target inner ::x::, not outer
            r = r .. "SKIP"
            ::x::
          end
          goto x  -- should target OUTER ::x:: (inner is out of scope)
        end
        return r
      '''), equals("AAA"));
    });

    // ================================================================
    // FUNCTIONS — goto is local to each function
    // ================================================================

    test('goto does not cross function boundaries', () {
      // Label in inner function is not visible to outer goto
      expectCompileError(r'''
        goto x
        local function f()
          ::x::
        end
      ''', 'no visible label');
    });

    test('independent goto/label in nested functions', () {
      expect(luaEval(r'''
        local function f()
          goto done
          ::done::
          return 1
        end
        local function g()
          goto done
          ::done::
          return 2
        end
        return f() + g()
      '''), equals(3));
    });

    // ================================================================
    // ERROR CASES
    // ================================================================

    test('error: duplicate label in same block', () {
      expectCompileError(r'''
        ::x::
        ::x::
      ''', 'already defined');
    });

    test('error: goto jumps over local (forward)', () {
      expectCompileError(r'''
        goto skip
        local x = 1
        ::skip::
      ''', 'local variable');
    });

    test('error: goto jumps over multiple locals', () {
      expectCompileError(r'''
        goto skip
        local a, b, c = 1, 2, 3
        ::skip::
      ''', 'local variable');
    });

    test('forward goto over do-end with locals inside is OK', () {
      // Locals inside a do-end are freed before the label
      expect(luaEval(r'''
        goto skip
        do
          local y = 2
          local z = 3
        end
        ::skip::
        return 1
      '''), equals(1));
    });

    test('error: unresolved goto (label in exited scope)', () {
      expectCompileError(r'''
        do
          ::inner::
        end
        goto inner
      ''', 'no visible label');
    });

    // ================================================================
    // COMPLEX PATTERNS
    // ================================================================

    test('continue pattern (goto end of loop body)', () {
      // Common use case: simulate "continue" with goto
      expect(luaEval(r'''
        local sum = 0
        for i = 1, 10 do
          if i % 2 == 0 then goto continue end
          sum = sum + i
          ::continue::
        end
        return sum
      '''), equals(25));
    });

    test('error recovery pattern', () {
      expect(luaEval(r'''
        local result = ""
        local items = {1, 0, 3, 0, 5}
        local i = 0
        ::next_item::
        i = i + 1
        if i > #items then goto done end
        if items[i] == 0 then
          result = result .. "skip,"
          goto next_item
        end
        result = result .. items[i] .. ","
        goto next_item
        ::done::
        return result
      '''), equals("1,skip,3,skip,5,"));
    });

    test('ping-pong between three labels', () {
      expect(luaEval(r'''
        local path = ""
        local step = 0
        goto a
        ::c::
        path = path .. "C"
        step = step + 1
        if step < 6 then goto a end
        goto done
        ::a::
        path = path .. "A"
        step = step + 1
        goto b
        ::b::
        path = path .. "B"
        step = step + 1
        goto c
        ::done::
        return path
      '''), equals("ABCABC"));
    });

    test('goto interleaved with pcall', () {
      expect(luaEval(r'''
        local ok, err
        local result
        goto start
        ::handle_error::
        result = "caught: " .. err
        goto done
        ::start::
        ok, err = pcall(function() error("boom") end)
        if not ok then goto handle_error end
        result = "no error"
        ::done::
        return result
      '''), contains("caught: "));
      // Also verify the error message contains 'boom'
      expect(luaEval(r'''
        local ok, err
        local result
        goto start
        ::handle_error::
        result = "caught"
        goto done
        ::start::
        ok, err = pcall(function() error("boom") end)
        if not ok then goto handle_error end
        result = "no error"
        ::done::
        return result
      '''), equals("caught"));
    });

    test('goto with string building (many iterations)', () {
      expect(luaEval(r'''
        local s = ""
        local i = 0
        ::loop::
        if i >= 50 then goto done end
        s = s .. "x"
        i = i + 1
        goto loop
        ::done::
        return #s
      '''), equals(50));
    });
  });
}
