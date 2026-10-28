import 'package:lua_dardo_plus/lua.dart';
import 'package:test/test.dart';

bool testTable() {
  try {
    LuaState state = LuaState.newState();
    state.openLibs();
    state.loadString(r'''
local arr = {"beta","alpha",}

table.insert(arr,1, "zeta")
table.insert(arr,2, "epsilon")
table.insert(arr,"delta")

print(table.concat(arr, ","))

table.remove(arr)

table.sort(arr)
print(table.concat(arr, ","))

local a1 = {"a","b","c","d"}
table.move(a1 ,1,#a1,4)
print(table.concat(a1, ",")) 
''');
    state.pCall(0, 0, 1);
  } catch (e, s) {
    print('$e\n$s');
    return false;
  }
  return true;
}

void main() {
  test('lua table standard library test', () {
    expect(testTable(), true);
  });

  // The wrap-around check uses luaMaxInteger, which was -1 under dart2js
  // ((1 << 63) - 1), so every table.move failed there.
  test('table.move shifts and copies on every platform', () {
    final state = LuaState.newState()..openLibs();
    state.loadString(r'''
      local t = {1, 2, 3}
      table.move(t, 1, 3, 2)
      local u = table.move({7, 8}, 1, 2, 1, {})
      return table.concat(t, ","), table.concat(u, ",")
    ''');
    state.call(0, 2);
    expect(state.toStr(-2), '1,1,2,3');
    expect(state.toStr(-1), '7,8');
  });
}
