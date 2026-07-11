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

  /// Executes `R(dest) = R(table)[RK(key)]` directly on VM registers.
  void getTableRK(int dest, int table, int key);

  /// Compares two RK operands without copying them to the VM stack.
  bool compareRK(int left, int right, CmpOp op);

  int registerCount();

  void loadVararg(int n);

  void loadProto(int idx);

  void closeUpvalues(int a);
}
