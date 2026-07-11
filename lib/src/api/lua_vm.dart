import 'lua_state.dart';
import 'lua_type.dart';

abstract class LuaVM extends LuaState {
  int getPC();

  void addPC(int n);

  int fetch();

  void getConst(int idx);

  void getRK(int rk);

  /// Executes `R(dest) = RK(b) op RK(c)` without routing operands through
  /// the public Lua stack API. Used by arithmetic bytecodes on the hot path.
  void binaryArithRK(int dest, int b, int c, ArithOp op);

  int registerCount();

  void loadVararg(int n);

  void loadProto(int idx);

  void closeUpvalues(int a);
}
