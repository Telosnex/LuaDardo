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

  /// Executes `R(table)[RK(key)] = RK(value)` directly on VM registers.
  void setTableRK(int table, int key, int value);

  /// Compares two RK operands without copying them to the VM stack.
  bool compareRK(int left, int right, CmpOp op);

  /// Copies consecutive registers into a table for SETLIST.
  void setListRegisters(int table, int count, int startIndex);

  int registerCount();

  void loadVararg(int n);

  void loadProto(int idx);

  void closeUpvalues(int a);
}
