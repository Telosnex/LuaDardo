import 'package:lua_dardo_plus/lua.dart';
import 'package:test/test.dart';

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

void expectCompileError(String code) {
  expect(
    () {
      LuaState ls = LuaState.newState();
      ls.openLibs();
      ls.loadString(code);
    },
    throwsA(anything),
    reason: 'Expected compile error for:\n$code',
  );
}

void main() {
  group('goto gremlin:', () {
    // ============================================================
    // THE UPVALUE GAUNTLET
    // ============================================================

    test('two closures capture same local, then goto out', () {
      expect(luaEval(r'''
        local f, g
        do
          local x = 99
          f = function() return x end
          g = function() return x + 1 end
          goto out
        end
        ::out::
        return f() + g()
      '''), equals(199));
    });

    test(
        'closure captures local, local mutated, goto out, closure sees mutation',
        () {
      expect(luaEval(r'''
        local f
        do
          local x = 1
          f = function() return x end
          x = 2
          x = 3
          x = 4
          x = 5
          goto out
        end
        ::out::
        return f()
      '''), equals(5));
    });

    test('nested closures: inner captures outer local, goto kills outer scope',
        () {
      expect(luaEval(r'''
        local result
        do
          local x = 10
          local f = function()
            return function() return x end
          end
          result = f()
          goto out
        end
        ::out::
        return result()
      '''), equals(10));
    });

    test('upvalue per iteration of goto-based loop', () {
      // each iteration of the goto loop creates a NEW local v,
      // captured by a NEW closure. They must be independent.
      expect(luaEval(r'''
        local t = {}
        local i = 0
        ::loop::
        i = i + 1
        do
          local v = i * 10
          t[i] = function() return v end
        end
        if i < 5 then goto loop end
        return t[1]() + t[2]() + t[3]() + t[4]() + t[5]()
      '''), equals(150));
    });

    test('upvalue closed by goto, then ANOTHER upvalue in a later block', () {
      expect(luaEval(r'''
        local f, g
        do
          local a = 1
          f = function() return a end
          goto mid
        end
        ::mid::
        do
          local b = 2
          g = function() return b end
          goto done
        end
        ::done::
        return f() * 10 + g()
      '''), equals(12));
    });

    test('goto out of THREE nested scopes, each with a captured upvalue', () {
      expect(luaEval(r'''
        local f1, f2, f3
        do
          local a = 1
          f1 = function() return a end
          do
            local b = 2
            f2 = function() return b end
            do
              local c = 3
              f3 = function() return c end
              goto out
            end
          end
        end
        ::out::
        return f1() * 100 + f2() * 10 + f3()
      '''), equals(123));
    });

    test('closure captures local from OUTER scope, goto exits INNER scope only',
        () {
      // The upvalue is in scope 1, goto exits scope 2.
      // The upvalue should NOT be closed prematurely.
      expect(luaEval(r'''
        local x = 42
        local f = function() return x end
        do
          local y = 99
          goto skip
        end
        ::skip::
        return f()
      '''), equals(42));
    });

    // ============================================================
    // SAME-NAME LABEL HELL
    // ============================================================

    test('three levels of same-name label nesting', () {
      expect(luaEval(r'''
        local r = ""
        ::L::
        r = r .. "a"
        if #r == 1 then
          do
            ::L::
            r = r .. "b"
            if #r == 2 then
              do
                ::L::
                r = r .. "c"
              end
              -- innermost ::L:: gone, middle ::L:: visible
              goto L
            end
          end
          -- middle ::L:: gone, outer ::L:: visible
          goto L
        end
        return r
      '''), equals("abcba"));
    });

    test('same label name in 5 sibling blocks', () {
      expect(luaEval(r'''
        local x = 0
        do goto s; x=99; ::s:: x=x+1 end
        do goto s; x=99; ::s:: x=x+1 end
        do goto s; x=99; ::s:: x=x+1 end
        do goto s; x=99; ::s:: x=x+1 end
        do goto s; x=99; ::s:: x=x+1 end
        return x
      '''), equals(5));
    });

    // ============================================================
    // GOTO + FOR LOOP INTERNALS
    // ============================================================

    test('continue in numeric for - skip even numbers', () {
      expect(luaEval(r'''
        local s = 0
        for i = 1, 20 do
          if i % 2 == 0 then goto cont end
          s = s + i
          ::cont::
        end
        return s
      '''), equals(100));
    });

    test('continue in generic for with pairs', () {
      expect(luaEval(r'''
        local t = {a=1, b=2, c=3, d=4, e=5}
        local s = 0
        for k, v in pairs(t) do
          if v % 2 == 0 then goto cont end
          s = s + v
          ::cont::
        end
        return s
      '''), equals(9));
    });

    test('continue in generic for with ipairs', () {
      expect(luaEval(r'''
        local t = {10, 20, 30, 40, 50}
        local r = ""
        for i, v in ipairs(t) do
          if v == 20 or v == 40 then goto skip end
          r = r .. v .. ","
          ::skip::
        end
        return r
      '''), equals("10,30,50,"));
    });

    test('goto out of generic for entirely', () {
      expect(luaEval(r'''
        local t = {10, 20, 30, 40, 50}
        local last = 0
        for i, v in ipairs(t) do
          if v > 25 then goto done end
          last = v
        end
        ::done::
        return last
      '''), equals(20));
    });

    test('nested numeric for + generic for, goto breaks both', () {
      expect(luaEval(r'''
        local r = ""
        for i = 1, 3 do
          for k, v in ipairs({"a","b","c"}) do
            if i == 2 and v == "b" then goto done end
            r = r .. i .. v .. " "
          end
        end
        ::done::
        return r
      '''), equals("1a 1b 1c 2a "));
    });

    // ============================================================
    // DEAD CODE / WEIRD ORDERING
    // ============================================================

    test('lots of dead code between goto and label', () {
      // Can't use local declarations (goto over local is an error).
      // Use do-end blocks so the locals are out of scope at the label.
      expect(luaEval(r'''
        local x = 0
        goto far_away
        do local _ = 1+1 end
        do local _ = 2+2 end
        do local _ = 3+3 end
        do local _ = 4+4 end
        do local _ = 5+5 end
        do local _ = 6+6 end
        do local _ = 7+7 end
        do local _ = 8+8 end
        do local _ = 9+9 end
        do local _ = 10+10 end
        do local _ = 11+11 end
        do local _ = 12+12 end
        do local _ = 13+13 end
        do local _ = 14+14 end
        do local _ = 15+15 end
        do local _ = 16+16 end
        do local _ = 17+17 end
        do local _ = 18+18 end
        do local _ = 19+19 end
        do local _ = 20+20 end
        ::far_away::
        return 777
      '''), equals(777));
    });

    test('goto skips function calls with side effects', () {
      expect(luaEval(r'''
        local log = ""
        local function track(s) log = log .. s end
        track("A")
        goto skip
        track("B")
        track("C")
        track("D")
        ::skip::
        track("E")
        return log
      '''), equals("AE"));
    });

    test('forward goto over multiple do blocks with locals', () {
      expect(luaEval(r'''
        goto target
        do local a = 1 end
        do local b = 2 end
        do local c = 3 end
        do local d = 4 end
        ::target::
        return 42
      '''), equals(42));
    });

    test('empty do blocks between goto and label', () {
      expect(luaEval(r'''
        goto x
        do end
        do end
        do end
        ::x::
        return 1
      '''), equals(1));
    });

    // ============================================================
    // GOTO-BASED STATE MACHINES
    // ============================================================

    test('simple state machine: count vowels', () {
      // local ch must be in a do-end block so goto done doesnt jump over it
      expect(luaEval(r'''
        local input = "hello world"
        local vowels = 0
        local i = 0

        ::next_char::
        i = i + 1
        if i > #input then goto done end
        do
          local ch = string.sub(input, i, i)
          if ch == "a" or ch == "e" or ch == "i"
             or ch == "o" or ch == "u" then
            vowels = vowels + 1
          end
        end
        goto next_char

        ::done::
        return vowels
      '''), equals(3));
    });

    test('goto-based fizzbuzz', () {
      expect(luaEval(r'''
        local r = ""
        local i = 0
        ::loop::
        i = i + 1
        if i > 15 then goto done end
        if i % 15 == 0 then r = r .. "FizzBuzz," goto loop end
        if i % 3 == 0 then r = r .. "Fizz," goto loop end
        if i % 5 == 0 then r = r .. "Buzz," goto loop end
        r = r .. i .. ","
        goto loop
        ::done::
        return r
      '''),
          equals("1,2,Fizz,4,Buzz,Fizz,7,8,Fizz,Buzz,11,Fizz,13,14,FizzBuzz,"));
    });

    test('goto-based binary search', () {
      // local mid must be in do-end so goto done doesnt jump over it
      expect(luaEval(r'''
        local arr = {2, 5, 8, 12, 16, 23, 38, 42, 56, 72, 91}
        local target = 23
        local lo, hi = 1, #arr
        local result = -1

        ::search::
        if lo > hi then goto done end
        do
          local mid = math.floor((lo + hi) / 2)
          if arr[mid] == target then
            result = mid
            goto done
          elseif arr[mid] < target then
            lo = mid + 1
          else
            hi = mid - 1
          end
        end
        goto search

        ::done::
        return result
      '''), equals(6));
    });

    // ============================================================
    // INTERACTION WITH OTHER CONTROL FLOW
    // ============================================================

    test('goto inside if-elseif-else chain', () {
      expect(luaEval(r'''
        local x = 3
        local r = ""
        if x == 1 then
          r = "one"
        elseif x == 2 then
          r = "two"
        elseif x == 3 then
          goto found_three
        else
          r = "other"
        end
        goto done
        ::found_three::
        r = "THREE!"
        ::done::
        return r
      '''), equals("THREE!"));
    });

    test('goto from inside while true do', () {
      expect(luaEval(r'''
        local n = 0
        while true do
          n = n + 1
          if n == 10 then goto escape end
        end
        ::escape::
        return n
      '''), equals(10));
    });

    test('break and goto coexist in same loop', () {
      expect(luaEval(r'''
        local r = ""
        for i = 1, 10 do
          if i == 3 then goto skip end
          if i == 7 then break end
          r = r .. tostring(i) .. ","
          ::skip::
        end
        return r
      '''), equals("1,2,4,5,6,"));
    });

    test('goto after do break end (dead code path)', () {
      expect(luaEval(r'''
        local r = 0
        for i = 1, 10 do
          r = r + i
          if i == 5 then
            do break end
          end
        end
        return r
      '''), equals(15));
    });

    // ============================================================
    // STRESS / DEGENERATE CASES
    // ============================================================

    test('50 forward gotos to the same label', () {
      expect(luaEval(r'''
        local x = 0
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        if false then goto target end
        x = 42
        ::target::
        return x
      '''), equals(42));
    });

    test('many labels in a row', () {
      expect(luaEval(r'''
        goto L10
        ::L1:: ::L2:: ::L3:: ::L4:: ::L5::
        ::L6:: ::L7:: ::L8:: ::L9:: ::L10::
        return 1
      '''), equals(1));
    });

    test('tight backward goto loop, 1000 iterations', () {
      expect(luaEval(r'''
        local n = 0
        ::top::
        n = n + 1
        if n < 1000 then goto top end
        return n
      '''), equals(1000));
    });

    test('goto-based loop building a table with 100 elements', () {
      expect(luaEval(r'''
        local t = {}
        local i = 0
        ::fill::
        i = i + 1
        t[i] = i * i
        if i < 100 then goto fill end
        return t[100]
      '''), equals(10000));
    });

    // ============================================================
    // REGISTER / LOCAL VARIABLE EDGE CASES
    // ============================================================

    test('goto skips local, but local is in a do-end (OK)', () {
      expect(luaEval(r'''
        goto over
        do
          local sneaky = 999
        end
        ::over::
        return 1
      '''), equals(1));
    });

    test('local declared after label, backward goto is fine', () {
      expect(luaEval(r'''
        local i = 0
        ::top::
        local x = i
        i = i + 1
        if i < 5 then goto top end
        return x
      '''), equals(4));
    });

    test('fresh local each goto-loop iteration', () {
      expect(luaEval(r'''
        local sum = 0
        local i = 0
        ::loop::
        i = i + 1
        local v = i * 10
        sum = sum + v
        if i < 5 then goto loop end
        return sum
      '''), equals(150));
    });

    test('register reuse: local exits scope, register reused after goto', () {
      expect(luaEval(r'''
        local result = 0
        do
          local a = 10
          result = result + a
        end
        goto next
        ::next::
        do
          local b = 20
          result = result + b
        end
        return result
      '''), equals(30));
    });

    // ============================================================
    // COMPILE ERRORS - the gremlin tries illegal things
    // ============================================================

    test('error: goto into a do block over local', () {
      expectCompileError(r'''
        goto inside
        local x = 1
        do
          ::inside::
          local y = x
        end
      ''');
    });

    test('error: forward goto jumps over local function', () {
      expectCompileError(r'''
        goto skip
        local function f() end
        ::skip::
      ''');
    });

    test('error: label not visible from inner function', () {
      expectCompileError(r'''
        ::outer::
        local function f()
          goto outer
        end
      ''');
    });

    test('error: goto to label in sibling function', () {
      expectCompileError(r'''
        local function f()
          goto x
        end
        local function g()
          ::x::
        end
      ''');
    });

    test('error: goto with no matching label at all', () {
      expectCompileError(r'''
        goto nonexistent
      ''');
    });

    test('error: goto over multiple locals', () {
      expectCompileError(r'''
        goto target
        local a = 1
        local b = 2
        local c = 3
        ::target::
      ''');
    });

    // ============================================================
    // INTERACTION WITH CLOSURES AND CALLBACKS
    // ============================================================

    test('goto inside pcall callback', () {
      expect(luaEval(r'''
        local r = ""
        local ok, err = pcall(function()
          r = r .. "A"
          goto skip
          r = r .. "B"
          ::skip::
          r = r .. "C"
        end)
        return r
      '''), equals("AC"));
    });

    test('goto-based retry pattern with pcall', () {
      expect(luaEval(r'''
        local attempts = 0
        local result
        ::retry::
        attempts = attempts + 1
        local ok, val = pcall(function()
          if attempts < 3 then error("not yet") end
          return "success"
        end)
        if not ok and attempts < 5 then goto retry end
        result = ok and val or "failed"
        return attempts .. ":" .. result
      '''), equals("3:success"));
    });

    test('goto inside function passed to table.sort', () {
      expect(luaEval(r'''
        local t = {3, 1, 4, 1, 5, 9}
        table.sort(t, function(a, b)
          if a == b then goto equal end
          do return a < b end
          ::equal::
          return false
        end)
        local r = ""
        for _, v in ipairs(t) do r = r .. tostring(v) .. "," end
        return r
      '''), equals("1,1,3,4,5,9,"));
    });

    // ============================================================
    // THE REALLY NASTY COMPOUND CASES
    // ============================================================

    test('goto + upvalue + same-name label + nested scope = nightmare', () {
      expect(luaEval(r'''
        local captures = {}
        local i = 0
        ::step::
        i = i + 1
        do
          local val = i
          captures[i] = function() return val end
          do
            ::step::
          end
        end
        if i < 4 then goto step end
        return captures[1]() .. "-" .. captures[2]() ..
               "-" .. captures[3]() .. "-" .. captures[4]()
      '''), equals("1-2-3-4"));
    });

    test('forward goto from deep scope, upvalues at every level', () {
      expect(luaEval(r'''
        local f1, f2, f3, f4
        do
          local a = "A"
          f1 = function() return a end
          do
            local b = "B"
            f2 = function() return b end
            do
              local c = "C"
              f3 = function() return c end
              do
                local d = "D"
                f4 = function() return d end
                goto escape
              end
            end
          end
        end
        ::escape::
        return f1() .. f2() .. f3() .. f4()
      '''), equals("ABCD"));
    });

    test('backward goto into scope that was exited and re-entered', () {
      // Each iteration creates a new scope. Upvalues from
      // previous iterations must be properly closed.
      expect(luaEval(r'''
        local closures = {}
        local n = 0
        ::again::
        n = n + 1
        do
          local x = n * 100
          closures[n] = function() return x end
        end
        if n < 3 then goto again end
        return closures[1]() + closures[2]() + closures[3]()
      '''), equals(600));
    });

    test('goto out of for-in loop that captures loop variables', () {
      expect(luaEval(r'''
        local captured_keys = {}
        local t = {x=1, y=2, z=3}
        for k, v in pairs(t) do
          captured_keys[#captured_keys + 1] = function() return k end
          if #captured_keys == 2 then goto done end
        end
        ::done::
        return type(captured_keys[1]()) .. "," .. type(captured_keys[2]())
      '''), equals("string,string"));
    });

    test('the monster: goto maze with upvalues and shadowed labels', () {
      expect(luaEval(r'''
        local r = ""
        local f

        goto start

        ::B::
        r = r .. "B"
        do
          local x = "fromB"
          f = function() return x end
          goto C
        end

        ::start::
        r = r .. "S"
        goto A

        ::C::
        r = r .. "C"
        r = r .. "[" .. f() .. "]"
        goto done

        ::A::
        r = r .. "A"
        goto B

        ::done::
        return r
      '''), equals("SABC[fromB]"));
    });

    test('goto-based coroutine-like alternation', () {
      // Two "threads" of execution that alternate via goto
      expect(luaEval(r'''
        local log = ""
        local turn = 1
        local countA = 0
        local countB = 0

        ::threadA::
        if countA >= 3 then goto finish end
        log = log .. "A"
        countA = countA + 1
        goto threadB

        ::threadB::
        if countB >= 3 then goto finish end
        log = log .. "B"
        countB = countB + 1
        goto threadA

        ::finish::
        return log
      '''), equals("ABABAB"));
    });

    test('goto + varargs', () {
      expect(luaEval(r'''
        local function f(...)
          local args = {...}
          local sum = 0
          local i = 0
          ::next::
          i = i + 1
          if i > #args then goto done end
          if args[i] < 0 then goto next end
          sum = sum + args[i]
          goto next
          ::done::
          return sum
        end
        return f(1, -2, 3, -4, 5)
      '''), equals(9));
    });

    test('goto inside nested if conditions all true', () {
      expect(luaEval(r'''
        local r = ""
        if true then
          if true then
            if true then
              if true then
                r = "deep"
                goto out
              end
            end
          end
        end
        r = "wrong"
        ::out::
        return r
      '''), equals("deep"));
    });

    test('goto inside nested if conditions all false paths', () {
      expect(luaEval(r'''
        local r = ""
        if false then
          goto a
        elseif false then
          goto b
        else
          goto c
        end
        ::a:: r = r .. "A" goto done
        ::b:: r = r .. "B" goto done
        ::c:: r = r .. "C"
        ::done::
        return r
      '''), equals("C"));
    });

    test('forward goto over a while loop', () {
      expect(luaEval(r'''
        goto skip_loop
        while true do
          -- this would infinite-loop if reached
        end
        ::skip_loop::
        return "survived"
      '''), equals("survived"));
    });

    test('forward goto over a repeat-until', () {
      expect(luaEval(r'''
        goto skip
        repeat
          -- infinite loop if reached
        until false
        ::skip::
        return "ok"
      '''), equals("ok"));
    });

    test('multiple gotos from different scopes to same label, varying depths',
        () {
      expect(luaEval(r'''
        local r = ""
        local path = 1

        if path == 1 then
          r = r .. "1"
          do
            r = r .. "a"
            do
              r = r .. "b"
              goto target
            end
          end
        elseif path == 2 then
          r = r .. "2"
          goto target
        else
          goto target
        end

        ::target::
        r = r .. "!"
        return r
      '''), equals("1ab!"));
    });

    test('label right at end of function body', () {
      // f(5) hits ::pos:: which is at the end — returns 0 values
      expect(luaEval(r'''
        local function f(x)
          if x > 0 then goto pos end
          if x < 0 then goto neg end
          do return "zero" end
          ::neg::
          do return "negative" end
          ::pos::
        end
        local r5 = f(5)  -- nil (0 return values)
        return tostring(r5) .. "," .. f(-3) .. "," .. f(0)
      '''), equals("nil,negative,zero"));
    });

    test('label at end of function, goto as last real action', () {
      expect(luaEval(r'''
        local function f()
          goto ending
          ::ending::
        end
        return f()
      '''), equals(null));
    });
  });
}
