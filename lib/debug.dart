import 'lua.dart';

_print(int i,LuaType type,[String? value]){
  var msg = "index:$i -> $type";
  if(value != null) msg += " value:$value";
  print(msg);
}

extension LuaStateDebug on LuaState {
  void printStack() {
    print(">------  stack  top  ------<");
    var len = getTop();
    for (int i = len; i >= 1; i--) {
      LuaType t = type(i);
      switch (type(i)) {
        case LuaType.luaNone:
          _print(i,t);
          break;

        case LuaType.luaNil:
          _print(i,t);
          break;

        case LuaType.luaBoolean:
          _print(i,t,toBoolean(i) ? "true" : "false");
          break;

        case LuaType.luaLightUserdata:
          _print(i, t);
          break;

        case LuaType.luaNumber:
          if (isInteger(i)) {
            _print(i,t,"(integer)${toInteger(i)}");
          } else if (isNumber(i)) {
            _print(i,t,"${toNumber(i)}");
          }
          break;

        case LuaType.luaString:
          _print(i,t,"${toStr(i)}");
          break;

        case LuaType.luaTable:
          _print(i,t);
          break;

        case LuaType.luaFunction:
          _print(i,t);
          break;

        case LuaType.luaUserdata:
          _print(i,t);
          break;

        case LuaType.luaThread:
          _print(i,t);
          break;
      }
    }
    print(">------ stack bottom ------<");
  }
}