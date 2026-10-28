import 'lua_aux_lib.dart';
import 'lua_basic_api.dart';
import 'lua_coroutine.dart';
import 'lua_debug.dart';
import '../state/lua_state_impl.dart';
import '../stdlib/constants.dart'
    if (dart.library.html) '../stdlib/constants_js.dart';

const luaMinStack = 20;
const luaMaxStack = 1000000;
const luaRegistryIndex = -luaMaxStack - 1000;
const luaMultret = -1;
const luaRidxGlobals = 2;

// 64-bit on the VM and dart2wasm. dart2js has no 64-bit integers, so there
// they are +-(2^53 - 1), as math.maxinteger is: (1 << 63) - 1 is -1 in
// JavaScript, and table.move then always failed "destination wrap around".
const luaMaxInteger = int64MaxValue;
const luaMinInteger = int64MinValue;

/// Returns the pseudo-index for an upvalue at the given index (1-based).
/// Use this in Dart closures to access upvalues pushed before the closure.
int luaUpvalueIndex(int i) => luaRegistryIndex - i;

/// Abstract base class for Lua state operations.
/// Combines basic API, auxiliary library, coroutine support, and debug features.
abstract class LuaState extends LuaBasicAPI
    implements LuaAuxLib, LuaCoroutineLib, LuaDebug {
  static LuaState newState() {
    return LuaStateImpl();
  }
}
