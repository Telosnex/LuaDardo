// Profiles with dart:io and the VM service.
@TestOn('vm')
library;

import 'package:test/test.dart' show TestOn;

// ignore_for_file: avoid_print
//
// Benchmarks the Lua stack representation: original growable List<Object?>
// vs. a fixed-capacity array with an explicit top pointer.
//
// The fixed-capacity stack eliminates:
//   - List.add / removeAt overhead on every push/pop
//   - The 3-allocation popN (loop + reversed + toList)
//   - The push/pop loops in setTop and pop(n)
//
// Run:
//   dart run test/perf/fixed_stack_perf_test.dart
//
// With CPU profiling:
//   dart run --enable-vm-service test/perf/fixed_stack_perf_test.dart

import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/src/state/lua_state_impl.dart';

import 'perf_tester.dart';

// ---------------------------------------------------------------------------
// Lua workloads — each stresses a different push/pop pattern.
// ---------------------------------------------------------------------------

/// Tight numeric for-loop.
/// Hot stack ops: push/pop for FORLOOP counter, ADD temporaries.
const _tightLoop = '''
local sum = 0
for i = 1, 500000 do
  sum = sum + i
end
return sum
''';

/// Table creation and indexed access.
/// Hot stack ops: setTop (nRegs) on each table-library call; many pushN/popN
/// from function call setup and return.
const _tableOps = '''
local t = {}
for i = 1, 50000 do
  t[i] = i * 2
end
local sum = 0
for i = 1, 50000 do
  sum = sum + t[i]
end
return sum
''';

/// Many small function calls — each call goes through pushN/popN/setTop.
/// This is the workload most sensitive to stack allocation overhead.
const _functionCalls = '''
local function add(a, b) return a + b end
local sum = 0
for i = 1, 100000 do
  sum = add(sum, i)
end
return sum
''';

/// Recursive Fibonacci — deep call stack with many frame create/destroy
/// cycles.  Each frame does: popN (args), pushN (args into new frame),
/// setTop (nRegs), then popN (results) on return.
const _fibonacci = '''
local function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
return fib(25)
''';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _runScript(String script) {
  final ls = LuaState.newState();
  ls.openLibs();
  ls.loadString(script);
  ls.pCall(0, 1, 0);
  return ls.toStr(-1) ?? 'nil';
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() async {
  final tester = PerfTester<String, String>(
    testName: 'Stack: growable List  vs  fixed-capacity array + top pointer',
    testCases: const [_tightLoop, _tableOps, _functionCalls, _fibonacci],
    implementation1: (script) {
      LuaStateImpl.useFixedStack = false;
      return _runScript(script);
    },
    implementation2: (script) {
      LuaStateImpl.useFixedStack = true;
      return _runScript(script);
    },
    impl1Name: 'Growable',
    impl2Name: 'Fixed',
  );

  await tester.run(
    warmupRuns: 10,
    benchmarkRuns: 50,
    profile: true,
  );
}
