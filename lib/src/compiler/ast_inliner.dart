import 'ast/block.dart';
import 'ast/exp.dart';
import 'ast/stat.dart';
import 'lexer/token.dart';

/// Conservatively inlines local functions consisting of one return expression.
///
/// Arguments are evaluated exactly once through compiler-generated [LetExp]
/// bindings. Normal lexical shadowing and reassignment remove candidates from
/// the current scope.
class _InlineTemplate {
  final FuncDefExp function;
  final List<String> localNames;
  final List<Exp> localValues;
  final Exp body;

  _InlineTemplate(this.function, this.localNames, this.localValues, this.body);
}

class AstInliner {
  static int _nextInlineId = 0;

  static Block optimize(Block block) {
    _nextInlineId = 0;
    _optimizeBlock(block, <String, _InlineTemplate>{});
    return block;
  }

  static void _optimizeBlock(
      Block block, Map<String, _InlineTemplate> inherited) {
    final functions = Map<String, _InlineTemplate>.of(inherited);
    for (final stat in block.stats) {
      if (stat is LocalFuncDefStat) {
        final nested = Map<String, _InlineTemplate>.of(functions)
          ..remove(stat.name);
        for (final parameter in stat.exp.parList) {
          nested.remove(parameter);
        }
        _optimizeBlock(stat.exp.block, nested);
        final template = _template(stat.exp);
        if (template != null) functions[stat.name] = template;
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
        final nested = Map<String, _InlineTemplate>.of(functions)
          ..remove(stat.varName);
        _optimizeBlock(stat.block, nested);
      } else if (stat is ForInStat) {
        stat.expList = stat.expList.map((e) => _rewrite(e, functions)).toList();
        final nested = Map<String, _InlineTemplate>.of(functions);
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

  static _InlineTemplate? _template(FuncDefExp function) {
    if (function.isVararg || function.block.retExps?.length != 1) return null;
    final localNames = <String>[];
    final localValues = <Exp>[];
    Exp? body;
    for (final stat in function.block.stats) {
      if (stat is LocalVarDeclStat &&
          stat.nameList.length == stat.expList.length &&
          body == null) {
        localNames.addAll(stat.nameList);
        localValues.addAll(stat.expList);
        continue;
      }
      if (stat is IfStat &&
          stat.exps.length == 1 &&
          stat.blocks.length == 1 &&
          stat.blocks.single.stats.isEmpty &&
          stat.blocks.single.retExps?.length == 1 &&
          body == null) {
        final whenTrue = stat.blocks.single.retExps!.single;
        if (!_alwaysTruthy(whenTrue)) return null;
        final and = BinopExp(Token(stat.line, TokenKind.TOKEN_OP_AND, ''),
            stat.exps.single, whenTrue);
        body = BinopExp(Token(stat.line, TokenKind.TOKEN_OP_OR, ''), and,
            function.block.retExps!.single);
        continue;
      }
      return null;
    }
    body ??= function.block.retExps!.single;
    if (_size(body) > 80) return null;
    final bound = <String>{...function.parList, ...localNames};
    if (_freeNames(body, bound).isNotEmpty ||
        localValues.any((value) => _freeNames(value, bound).isNotEmpty)) {
      return null;
    }
    return _InlineTemplate(function, localNames, localValues, body);
  }

  static bool _alwaysTruthy(Exp exp) =>
      exp is IntegerExp ||
      exp is FloatExp ||
      exp is StringExp ||
      exp is TableConstructorExp ||
      exp is BinopExp &&
          exp.op != TokenKind.TOKEN_OP_EQ &&
          exp.op != TokenKind.TOKEN_OP_NE &&
          exp.op != TokenKind.TOKEN_OP_LT &&
          exp.op != TokenKind.TOKEN_OP_LE &&
          exp.op != TokenKind.TOKEN_OP_GT &&
          exp.op != TokenKind.TOKEN_OP_GE &&
          exp.op != TokenKind.TOKEN_OP_AND &&
          exp.op != TokenKind.TOKEN_OP_OR;

  static Set<String> _freeNames(Exp exp, Set<String> bound) {
    final names = <String>{};
    void visit(Exp node, Set<String> scope) {
      if (node is NameExp) {
        if (!scope.contains(node.name)) names.add(node.name);
      } else if (node is BinopExp) {
        visit(node.exp1, scope);
        visit(node.exp2, scope);
      } else if (node is UnopExp) {
        visit(node.exp, scope);
      } else if (node is ConcatExp) {
        for (final child in node.exps) {
          visit(child, scope);
        }
      } else if (node is TableConstructorExp) {
        for (final child in node.keyExps) {
          if (child != null) visit(child, scope);
        }
        for (final child in node.valExps) {
          visit(child, scope);
        }
      } else if (node is LetExp) {
        final nested = <String>{...scope};
        for (int i = 0; i < node.names.length; i++) {
          visit(node.values[i], nested);
          nested.add(node.names[i]);
        }
        visit(node.body, nested);
      } else if (node is ParensExp) {
        visit(node.exp, scope);
      } else if (node is TableAccessExp) {
        visit(node.prefixExp, scope);
        visit(node.keyExp, scope);
      } else if (node is FuncCallExp) {
        visit(node.prefixExp, scope);
        for (final child in node.args) {
          visit(child, scope);
        }
      }
    }

    visit(exp, bound);
    return names;
  }

  static Exp _rewrite(Exp exp, Map<String, _InlineTemplate> functions) {
    if (exp is FuncCallExp) {
      exp.prefixExp = _rewrite(exp.prefixExp, functions);
      exp.args = exp.args.map((e) => _rewrite(e, functions)).toList();
      final target = exp.prefixExp;
      if (exp.nameExp == null && target is NameExp) {
        final template = functions[target.name];
        if (template != null &&
            template.function.parList.length == exp.args.length) {
          final id = _nextInlineId++;
          final names = <String>[];
          final values = <Exp>[...exp.args];
          final substitutions = <String, Exp>{};
          for (final parameter in template.function.parList) {
            final renamed = '(@inline$id:$parameter)';
            names.add(renamed);
            substitutions[parameter] = NameExp(exp.line, renamed);
          }
          for (int i = 0; i < template.localNames.length; i++) {
            values.add(_clone(template.localValues[i], substitutions));
            final local = template.localNames[i];
            final renamed = '(@inline$id:$local)';
            names.add(renamed);
            substitutions[local] = NameExp(exp.line, renamed);
          }
          return LetExp(names, values, _clone(template.body, substitutions),
              parameterCount: template.function.parList.length);
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
    } else if (exp is LetExp) {
      exp.values = exp.values.map((e) => _rewrite(e, functions)).toList();
      exp.body = _rewrite(exp.body, functions);
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
    if (exp is LetExp) {
      return LetExp(
          List<String>.of(exp.names),
          exp.values.map((e) => _clone(e, substitutions)).toList(),
          _clone(exp.body, substitutions),
          parameterCount: exp.parameterCount);
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
    if (exp is LetExp) {
      return 1 +
          exp.values.fold<int>(0, (sum, e) => sum + _size(e)) +
          _size(exp.body);
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
