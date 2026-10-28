// Profiles with dart:io and the VM service.
@TestOn('vm')
library;

import 'package:test/test.dart' show TestOn;

// ignore_for_file: avoid_print
//
// Benchmarks string.format: original (regex parse + sprintf every call)
// vs. optimised (cached parse + inline fast paths for %d/%s/%f).
//
// Run:
//   dart run test/perf/string_format_perf_test.dart

import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/src/stdlib/string_lib.dart';

import 'perf_tester.dart';

// ---------------------------------------------------------------------------
// Lua workloads — each stresses string.format differently.
// ---------------------------------------------------------------------------

/// The user's real-world countdown timer pattern: 4 × %d / %2d per call.
const _countdown = '''
local result
for i = 1, 50000 do
  result = string.format("%dd %dh %dm %2ds", i, i % 24, i % 60, i % 60)
end
return result
''';

/// Pure %d (simplest fast path).
const _pureIntFormat = '''
local result
for i = 1, 50000 do
  result = string.format("%d %d %d", i, i * 2, i * 3)
end
return result
''';

/// Mixed: %s and %d together.
const _mixedFormat = '''
local result
for i = 1, 50000 do
  result = string.format("name=%s id=%d", "hello", i)
end
return result
''';

/// Zero-padded and width specifiers: %02d, %05d.
const _paddedFormat = '''
local result
for i = 1, 50000 do
  result = string.format("%02d:%02d:%02d", i % 24, i % 60, i % 60)
end
return result
''';

/// Complex: %f, %e, %x — these still go through sprintf even in fast mode,
/// but the parse cache and StringBuffer still help.
const _complexFormat = '''
local result
for i = 1, 20000 do
  result = string.format("0x%x %.2f %e", i, i * 1.5, i * 0.001)
end
return result
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
    testName: 'string.format: sprintf every call  vs  cached parse + inline',
    testCases: const [
      _countdown,
      _pureIntFormat,
      _mixedFormat,
      _paddedFormat,
      _complexFormat,
    ],
    implementation1: (script) {
      StringLib.useFastFormat = false;
      return _runScript(script);
    },
    implementation2: (script) {
      StringLib.useFastFormat = true;
      return _runScript(script);
    },
    impl1Name: 'sprintf',
    impl2Name: 'Fast',
  );

  await tester.run(
    warmupRuns: 5,
    benchmarkRuns: 30,
    profile: true,
  );
}
