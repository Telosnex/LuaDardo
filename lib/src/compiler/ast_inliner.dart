import 'ast/block.dart';
import 'ast/exp.dart';
import 'ast/stat.dart';
import 'lexer/token.dart';

/// Conservatively inlines local functions consisting of one return expression.
///
/// Arguments must be simple values (names or literals), so substituting them
/// cannot duplicate side effects. Normal lexical shadowing and reassignment
/// remove candidates from the current scope.
class AstInliner {
  static Block optimize(Block block) {
    _optimizeBlock(block, <String, FuncDefExp>{});
    return block;
  }

  static void _optimizeBlock(Block block, Map<String, FuncDefExp> inherited) {
    final functions = Map<String, FuncDefExp>.of(inherited);
    for (final stat in block.stats) {
      if (stat is LocalFuncDefStat) {
        final nested = Map<String, FuncDefExp>.of(functions)..remove(stat.name);
        for (final parameter in stat.exp.parList) {
          nested.remove(parameter);
        }
        _optimizeBlock(stat.exp.block, nested);
        if (_isCandidate(stat.exp)) functions[stat.name] = stat.exp;
      } else if (stat is LocalVarDeclStat) {
        stat.expList = stat.expList.map((e) => _rewrite(e, functions)).toList();
        for (final name in stat.nameList) {
          functions.remove(name);
        }
      } else if (stat is AssignStat) {
        stat.expList = stat.expList.map((e) => _rewrite(e, functions)).toList();
        stat.varList = stat.varList.map((e) => _rewrite(e, functions)).toList();
        for (final variable in stat.varList) {
          if (variable is NameExp) functions.remove(variable.name);
        }
      } else if (stat is FuncCallStat) {
        stat.exp = _rewrite(stat.exp, functions) as FuncCallExp;
      } else if (stat is DoStat) {
        _optimizeBlock(stat.block, functions);
      } else if (stat is WhileStat) {
        stat.exp = _rewrite(stat.exp, functions);
        _optimizeBlock(stat.block, functions);
      } else if (stat is RepeatStat) {
        _optimizeBlock(stat.block, functions);
        stat.exp = _rewrite(stat.exp, functions);
      } else if (stat is IfStat) {
        stat.exps = stat.exps.map((e) => _rewrite(e, functions)).toList();
        for (final child in stat.blocks) {
          _optimizeBlock(child, functions);
        }
      } else if (stat is ForNumStat) {
        stat.initExp = _rewrite(stat.initExp, functions);
        stat.limitExp = _rewrite(stat.limitExp, functions);
        stat.stepExp = _rewrite(stat.stepExp, functions);
        final nested = Map<String, FuncDefExp>.of(functions)
          ..remove(stat.varName);
        _optimizeBlock(stat.block, nested);
      } else if (stat is ForInStat) {
        stat.expList = stat.expList.map((e) => _rewrite(e, functions)).toList();
        final nested = Map<String, FuncDefExp>.of(functions);
        for (final name in stat.nameList) {
          nested.remove(name);
        }
        _optimizeBlock(stat.block, nested);
      }
    }
    if (block.retExps != null) {
      block.retExps =
          block.retExps!.map((e) => _rewrite(e, functions)).toList();
    }
  }

  static bool _isCandidate(FuncDefExp function) =>
      !function.isVararg &&
      function.block.stats.isEmpty &&
      function.block.retExps?.length == 1 &&
      _size(function.block.retExps!.single) <= 40;

  static bool _simpleArgument(Exp exp) =>
      exp is NameExp ||
      exp is NilExp ||
      exp is TrueExp ||
      exp is FalseExp ||
      exp is IntegerExp ||
      exp is FloatExp ||
      exp is StringExp;

  static Exp _rewrite(Exp exp, Map<String, FuncDefExp> functions) {
    if (exp is FuncCallExp) {
      exp.prefixExp = _rewrite(exp.prefixExp, functions);
      exp.args = exp.args.map((e) => _rewrite(e, functions)).toList();
      final target = exp.prefixExp;
      if (exp.nameExp == null && target is NameExp) {
        final function = functions[target.name];
        if (function != null &&
            function.parList.length == exp.args.length &&
            exp.args.every(_simpleArgument)) {
          final substitutions = <String, Exp>{};
          for (int i = 0; i < function.parList.length; i++) {
            substitutions[function.parList[i]] = exp.args[i];
          }
          return ParensExp(
              _clone(function.block.retExps!.single, substitutions));
        }
      }
      return exp;
    }
    if (exp is BinopExp) {
      exp.exp1 = _rewrite(exp.exp1, functions);
      exp.exp2 = _rewrite(exp.exp2, functions);
    } else if (exp is UnopExp) {
      exp.exp = _rewrite(exp.exp, functions);
    } else if (exp is ConcatExp) {
      exp.exps = exp.exps.map((e) => _rewrite(e, functions)).toList();
    } else if (exp is TableConstructorExp) {
      exp.keyExps = exp.keyExps
          .map((e) => e == null ? null : _rewrite(e, functions))
          .toList();
      exp.valExps = exp.valExps.map((e) => _rewrite(e, functions)).toList();
    } else if (exp is ParensExp) {
      exp.exp = _rewrite(exp.exp, functions);
    } else if (exp is TableAccessExp) {
      exp.prefixExp = _rewrite(exp.prefixExp, functions);
      exp.keyExp = _rewrite(exp.keyExp, functions);
    } else if (exp is FuncDefExp) {
      _optimizeBlock(exp.block, functions);
    }
    return exp;
  }

  static Exp _clone(Exp exp, Map<String, Exp> substitutions) {
    if (exp is NameExp) {
      final replacement = substitutions[exp.name];
      return replacement == null
          ? NameExp(exp.line, exp.name)
          : _clone(replacement, const {});
    }
    if (exp is NilExp) return NilExp(exp.line);
    if (exp is TrueExp) return TrueExp(exp.line);
    if (exp is FalseExp) return FalseExp(exp.line);
    if (exp is IntegerExp) return IntegerExp(exp.line, exp.val);
    if (exp is FloatExp) return FloatExp(exp.line, exp.val);
    if (exp is StringExp) return StringExp(exp.line, exp.str);
    if (exp is BinopExp) {
      return BinopExp(Token(exp.line, exp.op, ''),
          _clone(exp.exp1, substitutions), _clone(exp.exp2, substitutions));
    }
    if (exp is UnopExp) {
      return UnopExp(
          Token(exp.line, exp.op, ''), _clone(exp.exp, substitutions));
    }
    if (exp is ConcatExp) {
      return ConcatExp(
          exp.line, exp.exps.map((e) => _clone(e, substitutions)).toList());
    }
    if (exp is TableConstructorExp) {
      final result = TableConstructorExp();
      result.line = exp.line;
      result.lastLine = exp.lastLine;
      result.keyExps = exp.keyExps
          .map((e) => e == null ? null : _clone(e, substitutions))
          .toList();
      result.valExps =
          exp.valExps.map((e) => _clone(e, substitutions)).toList();
      return result;
    }
    if (exp is ParensExp) return ParensExp(_clone(exp.exp, substitutions));
    if (exp is TableAccessExp) {
      return TableAccessExp(exp.lastLine, _clone(exp.prefixExp, substitutions),
          _clone(exp.keyExp, substitutions));
    }
    if (exp is FuncCallExp) {
      return FuncCallExp(
        prefixExp: _clone(exp.prefixExp, substitutions),
        nameExp: exp.nameExp == null
            ? null
            : StringExp(exp.nameExp!.line, exp.nameExp!.str),
        args: exp.args.map((e) => _clone(e, substitutions)).toList(),
      );
    }
    throw StateError('unsupported inline expression ${exp.runtimeType}');
  }

  static int _size(Exp exp) {
    if (exp is BinopExp) return 1 + _size(exp.exp1) + _size(exp.exp2);
    if (exp is UnopExp) return 1 + _size(exp.exp);
    if (exp is ConcatExp) {
      return 1 + exp.exps.fold<int>(0, (sum, e) => sum + _size(e));
    }
    if (exp is TableConstructorExp) {
      return 1 +
          exp.keyExps
              .fold<int>(0, (sum, e) => sum + (e == null ? 0 : _size(e))) +
          exp.valExps.fold<int>(0, (sum, e) => sum + _size(e));
    }
    if (exp is ParensExp) {
      return 1 + _size(exp.exp);
    }
    if (exp is TableAccessExp) {
      return 1 + _size(exp.prefixExp) + _size(exp.keyExp);
    }
    if (exp is FuncCallExp) {
      return 1 +
          _size(exp.prefixExp) +
          exp.args.fold<int>(0, (sum, e) => sum + _size(e));
    }
    return 1;
  }
}
