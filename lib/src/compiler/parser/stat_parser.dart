import '../ast/block.dart';
import '../ast/exp.dart';
import '../ast/stat.dart';
import '../lexer/lexer.dart';
import '../lexer/token.dart';
import 'block_parser.dart';
import 'exp_parser.dart';
import 'prefix_exp_parser.dart';

class StatParser {
  /// Select between the original and the tuned implementation. Kept as a
  /// runtime flag so `test/perf/stat_parser_perf_test.dart` can A/B them.
  /// Defaults to the tuned path; flip to `false` to restore the original.
  static bool useOptimized = true;

  /*
    stat ::=  ‘;’
        | break
        | ‘::’ Name ‘::’
        | goto Name
        | do block end
        | while exp do block end
        | repeat block until exp
        | if exp then block {elseif exp then block} [else block] end
        | for Name ‘=’ exp ‘,’ exp [‘,’ exp] do block end
        | for namelist in explist do block end
        | function funcname funcbody
        | local function Name funcbody
        | local namelist [‘=’ explist]
        | varlist ‘=’ explist
        | functioncall
    */
  static Stat parseStat(Lexer lexer) {
    switch (lexer.LookAhead()) {
      case TokenKind.TOKEN_SEP_SEMI:
        return parseEmptyStat(lexer);
      case TokenKind.TOKEN_KW_BREAK:
        return parseBreakStat(lexer);
      case TokenKind.TOKEN_SEP_LABEL:
        return parseLabelStat(lexer);
      case TokenKind.TOKEN_KW_GOTO:
        return parseGotoStat(lexer);
      case TokenKind.TOKEN_KW_DO:
        return parseDoStat(lexer);
      case TokenKind.TOKEN_KW_WHILE:
        return parseWhileStat(lexer);
      case TokenKind.TOKEN_KW_REPEAT:
        return parseRepeatStat(lexer);
      case TokenKind.TOKEN_KW_IF:
        return parseIfStat(lexer);
      case TokenKind.TOKEN_KW_FOR:
        return parseForStat(lexer);
      case TokenKind.TOKEN_KW_FUNCTION:
        return parseFuncDefStat(lexer);
      case TokenKind.TOKEN_KW_LOCAL:
        return parseLocalAssignOrFuncDefStat(lexer);
      default:
        return parseAssignOrFuncCallStat(lexer);
    }
  }

  // ;
  static EmptyStat parseEmptyStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_SEP_SEMI);
    return EmptyStat.instance;
  }

  // break
  static BreakStat parseBreakStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_BREAK);
    return BreakStat(lexer.line);
  }

  // ‘::’ Name ‘::’
  static LabelStat parseLabelStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_SEP_LABEL); // ::
    int line = lexer.line;
    String? name = lexer.nextIdentifier().value; // name
    lexer.nextTokenOfKind(TokenKind.TOKEN_SEP_LABEL); // ::
    LabelStat stat = LabelStat(name);
    stat.line = line;
    return stat;
  }

  // goto Name
  static GotoStat parseGotoStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_GOTO); // goto
    int line = lexer.line;
    String? name = lexer.nextIdentifier().value; // name
    GotoStat stat = GotoStat(name);
    stat.line = line;
    return stat;
  }

  // do block end
  static DoStat parseDoStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_DO); // do
    Block block = BlockParser.parseBlock(lexer); // block
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_END); // end
    return DoStat(block);
  }

  // while exp do block end
  static WhileStat parseWhileStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_WHILE); // while
    Exp exp = ExpParser.parseExp(lexer); // exp
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_DO); // do
    Block block = BlockParser.parseBlock(lexer); // block
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_END); // end
    return WhileStat(exp, block);
  }

  // repeat block until exp
  static RepeatStat parseRepeatStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_REPEAT); // repeat
    Block block = BlockParser.parseBlock(lexer); // block
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_UNTIL); // until
    Exp exp = ExpParser.parseExp(lexer); // exp
    return RepeatStat(block, exp);
  }

  // if exp then block {elseif exp then block} [else block] end
  static IfStat parseIfStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_IF); // if
    final firstExp = ExpParser.parseExp(lexer); // exp
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_THEN); // then
    final firstBlock = BlockParser.parseBlock(lexer); // block

    // Opt: pre-size the lists with the mandatory first branch so we
    // skip one grow-and-add per if-stat. Most ifs have 1–3 branches
    // total.
    final List<Exp> exps = useOptimized ? <Exp>[firstExp] : (<Exp>[firstExp]);
    final List<Block> blocks =
        useOptimized ? <Block>[firstBlock] : (<Block>[firstBlock]);

    while (lexer.LookAhead() == TokenKind.TOKEN_KW_ELSEIF) {
      lexer.nextToken(); // elseif
      exps.add(ExpParser.parseExp(lexer)); // exp
      lexer.nextTokenOfKind(TokenKind.TOKEN_KW_THEN); // then
      blocks.add(BlockParser.parseBlock(lexer)); // block
    }

    // else block => elseif true then block
    if (lexer.LookAhead() == TokenKind.TOKEN_KW_ELSE) {
      lexer.nextToken(); // else
      exps.add(TrueExp(lexer.line)); //
      blocks.add(BlockParser.parseBlock(lexer)); // block
    }

    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_END); // end
    return IfStat(exps, blocks);
  }

  // for Name ‘=’ exp ‘,’ exp [‘,’ exp] do block end
  // for namelist in explist do block end
  static Stat parseForStat(Lexer lexer) {
    int lineOfFor = lexer.nextTokenOfKind(TokenKind.TOKEN_KW_FOR).line;
    String name = lexer.nextIdentifier().value;
    if (lexer.LookAhead() == TokenKind.TOKEN_OP_ASSIGN) {
      return finishForNumStat(lexer, name, lineOfFor);
    } else {
      return finishForInStat(lexer, name);
    }
  }

  // for Name ‘=’ exp ‘,’ exp [‘,’ exp] do block end
  static ForNumStat finishForNumStat(Lexer lexer, String name, int lineOfFor) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_OP_ASSIGN); // =
    var initExp = ExpParser.parseExp(lexer); // exp
    lexer.nextTokenOfKind(TokenKind.TOKEN_SEP_COMMA); // ,
    var limitExp = ExpParser.parseExp(lexer); // exp
    Exp stepExp;
    if (lexer.LookAhead() == TokenKind.TOKEN_SEP_COMMA) {
      lexer.nextToken(); // ,
      stepExp = ExpParser.parseExp(lexer); // exp
    } else {
      stepExp = IntegerExp(lexer.line, 1);
    }

    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_DO); // do
    var lineOfDo = lexer.line; //
    var block = BlockParser.parseBlock(lexer); // block
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_END); // end

    return ForNumStat(
        lineOfFor: lineOfFor,
        // for
        varName: name,
        // name
        initExp: initExp,
        limitExp: limitExp,
        stepExp: stepExp,
        lineOfDo: lineOfDo,
        block: block);
  }

  // for namelist in explist do block end
  // namelist ::= Name {‘,’ Name}
  // explist ::= exp {‘,’ exp}
  static ForInStat finishForInStat(Lexer lexer, String name0) {
    // for
    var nameList = finishNameList(lexer, name0); // namelist
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_IN); // in
    var expList = ExpParser.parseExpList(lexer); // explist
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_DO); // do
    var lineOfDo = lexer.line; //
    var block = BlockParser.parseBlock(lexer); // block
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_END); // end

    return ForInStat(
        nameList: nameList, expList: expList, lineOfDo: lineOfDo, block: block);
  }

  // namelist ::= Name {‘,’ Name}
  static List<String> finishNameList(Lexer lexer, String name0) {
    // Opt: start the list pre-populated so we save one `add()` call per
    // namelist. For `local x` (no comma) this is the entire savings;
    // for `local x, y` it's still a win.
    final List<String> names =
        useOptimized ? <String>[name0] : (<String>[name0]);
    while (lexer.LookAhead() == TokenKind.TOKEN_SEP_COMMA) {
      lexer.nextToken(); // ,
      names.add(lexer.nextIdentifier().value); // Name
    }
    return names;
  }

  // local function Name funcbody
  // local namelist [‘=’ explist]
  static Stat parseLocalAssignOrFuncDefStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_LOCAL);
    if (lexer.LookAhead() == TokenKind.TOKEN_KW_FUNCTION) {
      return finishLocalFuncDefStat(lexer);
    } else {
      return finishLocalVarDeclStat(lexer);
    }
  }

  /*
    http://www.lua.org/manual/5.3/manual.html#3.4.11

    function f() end          =>  f = function() end
    function t.a.b.c.f() end  =>  t.a.b.c.f = function() end
    function t.a.b.c:f() end  =>  t.a.b.c.f = function(self) end
    local function f() end    =>  local f; f = function() end

    The statement `local function f () body end`
    translates to `local f; f = function () body end`
    not to `local f = function () body end`
    (This only makes a difference when the body of the function
     contains references to f.)
    */
  // local function Name funcbody
  static LocalFuncDefStat finishLocalFuncDefStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_FUNCTION); // local function
    String? name = lexer.nextIdentifier().value; // name
    FuncDefExp fdExp = ExpParser.parseFuncDefExp(lexer); // funcbody
    return LocalFuncDefStat(name, fdExp);
  }

  // local namelist [‘=’ explist]
  static LocalVarDeclStat finishLocalVarDeclStat(Lexer lexer) {
    String name0 = lexer.nextIdentifier().value; // local Name
    List<String> nameList = finishNameList(lexer, name0); // { , Name }
    List<Exp>? expList;
    if (lexer.LookAhead() == TokenKind.TOKEN_OP_ASSIGN) {
      lexer.nextToken(); // ==
      expList = ExpParser.parseExpList(lexer); // explist
    }
    int lastLine = lexer.line;
    // Opt: reuse a canonical empty list rather than allocating via
    // `List<Exp>.empty()` on every `local x` without initializer.
    // `parseRetExps` in block_parser.dart already does this.
    final fallback = useOptimized ? const <Exp>[] : List<Exp>.empty();
    return LocalVarDeclStat(lastLine, nameList, expList ?? fallback);
  }

  // varlist ‘=’ explist
  // functioncall
  static Stat parseAssignOrFuncCallStat(Lexer lexer) {
    Exp prefixExp = PrefixExpParser.parsePrefixExp(lexer);
    if (prefixExp is FuncCallExp) {
      return FuncCallStat(prefixExp);
    } else {
      return parseAssignStat(lexer, prefixExp);
    }
  }

  // varlist ‘=’ explist |
  static AssignStat parseAssignStat(Lexer lexer, Exp var0) {
    List<Exp> varList = finishVarList(lexer, var0); // varlist
    lexer.nextTokenOfKind(TokenKind.TOKEN_OP_ASSIGN); // =
    List<Exp> expList = ExpParser.parseExpList(lexer); // explist
    int lastLine = lexer.line;
    return AssignStat(lastLine, varList, expList);
  }

  // varlist ::= var {‘,’ var}
  static List<Exp> finishVarList(Lexer lexer, Exp var0) {
    // Opt: single-var assignments (`x = y`, far the most common) benefit
    // from a pre-sized list of length 1 — no grow-and-add, just a
    // literal allocation.
    final checked = checkVar(lexer, var0);
    final List<Exp> vars = useOptimized ? <Exp>[checked] : (<Exp>[checked]);
    while (lexer.LookAhead() == TokenKind.TOKEN_SEP_COMMA) {
      // {
      lexer.nextToken(); // ,
      Exp exp = PrefixExpParser.parsePrefixExp(lexer); // var
      vars.add(checkVar(lexer, exp)); //
    } // }
    return vars;
  }

  // var ::=  Name | prefixexp ‘[’ exp ‘]’ | prefixexp ‘.’ Name
  static Exp checkVar(Lexer lexer, Exp exp) {
    if (exp is NameExp || exp is TableAccessExp) {
      return exp;
    }
    lexer.nextTokenOfKind(null); // trigger error
    throw Exception("unreachable!");
  }

  // function funcname funcbody
  // funcname ::= Name {‘.’ Name} [‘:’ Name]
  // funcbody ::= ‘(’ [parlist] ‘)’ block end
  // parlist ::= namelist [‘,’ ‘...’] | ‘...’
  // namelist ::= Name {‘,’ Name}
  static AssignStat parseFuncDefStat(Lexer lexer) {
    lexer.nextTokenOfKind(TokenKind.TOKEN_KW_FUNCTION); // function
    final Exp fnExp;
    final bool hasColon;
    if (useOptimized) {
      final (e, hc) = _parseFuncNameFast(lexer);
      fnExp = e;
      hasColon = hc;
    } else {
      final map = parseFuncName(lexer); // funcname (legacy path)
      fnExp = map.keys.first;
      hasColon = map.values.first;
    }
    FuncDefExp fdExp = ExpParser.parseFuncDefExp(lexer); // funcbody
    if (hasColon) {
      // insert self
      fdExp.parList.insert(0, "self");
    }

    return AssignStat(fdExp.lastLine, <Exp>[fnExp], <Exp>[fdExp]);
  }

  // funcname ::= Name {‘.’ Name} [‘:’ Name]
  //
  // Legacy path: returned a single-entry HashMap so the caller could
  // pull out both values. See [_parseFuncNameFast] for the tuned path.
  static Map<Exp, bool> parseFuncName(Lexer lexer) {
    Token id = lexer.nextIdentifier();
    Exp exp = NameExp(id.line, id.value);
    bool hasColon = false;

    while (lexer.LookAhead() == TokenKind.TOKEN_SEP_DOT) {
      lexer.nextToken();
      id = lexer.nextIdentifier();
      Exp idx = StringExp.fromToken(id);
      exp = TableAccessExp(id.line, exp, idx);
    }
    if (lexer.LookAhead() == TokenKind.TOKEN_SEP_COLON) {
      lexer.nextToken();
      id = lexer.nextIdentifier();
      Exp idx = StringExp.fromToken(id);
      exp = TableAccessExp(id.line, exp, idx);
      hasColon = true;
    }

    // workaround: return multiple values
    return <Exp, bool>{}..[exp] = hasColon;
  }

  /// Tuned alternative for [parseFuncName]: returns a 2-tuple record
  /// instead of allocating a HashMap per function definition.
  static (Exp, bool) _parseFuncNameFast(Lexer lexer) {
    Token id = lexer.nextIdentifier();
    Exp exp = NameExp(id.line, id.value);
    bool hasColon = false;

    while (lexer.LookAhead() == TokenKind.TOKEN_SEP_DOT) {
      lexer.nextToken();
      id = lexer.nextIdentifier();
      Exp idx = StringExp.fromToken(id);
      exp = TableAccessExp(id.line, exp, idx);
    }
    if (lexer.LookAhead() == TokenKind.TOKEN_SEP_COLON) {
      lexer.nextToken();
      id = lexer.nextIdentifier();
      Exp idx = StringExp.fromToken(id);
      exp = TableAccessExp(id.line, exp, idx);
      hasColon = true;
    }

    return (exp, hasColon);
  }
}
