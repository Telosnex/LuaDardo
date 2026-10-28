import 'dart:convert';

import 'char_sequence.dart';
import 'token.dart';

// ── Single-char ASCII code-unit constants ─────────────────────────
// Named so the jump-table switch in [_nextTokenFast] reads cleanly.
const int _chLF = 10;
const int _chCR = 13;
const int _chQuote = 34;    // "
const int _chHash = 35;     // #
const int _chPercent = 37;  // %
const int _chAmp = 38;      // &
const int _chApos = 39;     // '
const int _chLParen = 40;   // (
const int _chRParen = 41;   // )
const int _chStar = 42;     // *
const int _chPlus = 43;     // +
const int _chComma = 44;    // ,
const int _chMinus = 45;    // -
const int _chDot = 46;      // .
const int _chSlash = 47;    // /
const int _chColon = 58;    // :
const int _chSemi = 59;     // ;
const int _chLt = 60;       // <
const int _chEq = 61;       // =
const int _chGt = 62;       // >
const int _chLBrack = 91;   // [
const int _chRBrack = 93;   // ]
const int _chCaret = 94;    // ^
const int _chUnderscore = 95; // _
const int _chLCurly = 123;  // {
const int _chPipe = 124;    // |
const int _chRCurly = 125;  // }
const int _chTilde = 126;   // ~

/// 词法分析器
class Lexer {
  /// A/B toggle for the tuned code-unit dispatch path in [nextToken] and
  /// [skipWhiteSpaces]. Default on; flip to `false` to restore the
  /// original String-based dispatch. See
  /// `test/perf/lexer_perf_test.dart`.
  static bool useFast = true;

  /// 源码
  CharSequence chunk;
  /// 源文件名
  String chunkName;
  /// 当前行号
  int line;

  // to support lookahead
  Token? cachedNextToken;
  int? lineBackup;

  final StringBuffer _buff = StringBuffer();

  Lexer(this.chunk,this.chunkName):line=1;

  TokenKind LookAhead() {
    if (cachedNextToken == null) {
      lineBackup = line;
      cachedNextToken = nextToken();
    }
    return cachedNextToken!.kind;
  }

  Token nextTokenOfKind(TokenKind? kind) {
    Token token = nextToken();
    if (token.kind != kind) {
      error("syntax error near '${token.value}'");
    }
    return token;
  }

  Token nextIdentifier() {
    return nextTokenOfKind(TokenKind.TOKEN_IDENTIFIER);
  }

  Token nextToken() {
    if (useFast) return _nextTokenFast();

    if (cachedNextToken != null) {
      Token token = cachedNextToken!;
      cachedNextToken = null;
      return token;
    }

    skipWhiteSpaces();
    if (chunk.length <= 0) {
      return Token(line, TokenKind.TOKEN_EOF, "EOF");
    }

    _buff.clear();
    switch (chunk.current) {
      case ';': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_SEMI,   ";");
      case ',': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_COMMA,  ",");
      case '(': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_LPAREN, "(");
      case ')': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_RPAREN, ")");
      case ']': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_RBRACK, "]");
      case '{': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_LCURLY, "{");
      case '}': chunk.next(1); return  Token(line, TokenKind.TOKEN_SEP_RCURLY, "}");
      case '+': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_ADD,     "+");
      case '-': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_MINUS,   "-");
      case '*': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_MUL,     "*");
      case '^': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_POW,     "^");
      case '%': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_MOD,     "%");
      case '&': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_BAND,    "&");
      case '|': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_BOR,     "|");
      case '#': chunk.next(1); return  Token(line, TokenKind.TOKEN_OP_LEN,     "#");
      case ':':
        if (chunk.startsWith("::")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_SEP_LABEL, "::");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_SEP_COLON, ":");
        }
      case '/':
        if (chunk.startsWith("//")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_IDIV, "//");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_OP_DIV, "/");
        }
      case '~':
        if (chunk.startsWith("~=")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_NE, "~=");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_OP_WAVE, "~");
        }
      case '=':
        if (chunk.startsWith("==")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_EQ, "==");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_OP_ASSIGN, "=");
        }
      case '<':
        if (chunk.startsWith("<<")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_SHL, "<<");
        } else if (chunk.startsWith("<=")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_LE, "<=");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_OP_LT, "<");
        }
      case '>':
        if (chunk.startsWith(">>")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_SHR, ">>");
        } else if (chunk.startsWith(">=")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_GE, ">=");
        } else {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_OP_GT, ">");
        }
      case '.':
        if (chunk.startsWith("...")) {
          chunk.next(3);
          return  Token(line, TokenKind.TOKEN_VARARG, "...");
        } else if (chunk.startsWith("..")) {
          chunk.next(2);
          return  Token(line, TokenKind.TOKEN_OP_CONCAT, "..");
        } else if (chunk.length == 1) {
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_SEP_DOT, ".");
        }else if(!CharSequence.isDigit(chunk.charAt(1))){
          chunk.next(1);
          return  Token(line, TokenKind.TOKEN_SEP_DOT, ".");
        }else{  // is digit
          return Token(line, TokenKind.TOKEN_NUMBER, readNumeral());
        }
      case '[':  // long string or simply '['
        int sep = _skip_sep();
        if (sep >= 0) {
          return Token(line, TokenKind.TOKEN_STRING, readLongString(true, sep));
        } else if (sep == -1) {
          return Token(line, TokenKind.TOKEN_SEP_LBRACK, "[");
        } else {
          error("invalid long string delimiter");
        }

        break;
      case '\'':
      case '"':
        return  Token(line, TokenKind.TOKEN_STRING, readString());
    }

    if (CharSequence.isDigit(chunk.current)) {
      return Token(line, TokenKind.TOKEN_NUMBER, readNumeral());
    }

    if (chunk.current == '_' || CharSequence.isLetter(chunk.current)) {
      do {
        _save_and_next();
      } while (CharSequence.isalnum(chunk.current) || chunk.current == '_');
      String id = _buff.toString();
      return keywords.containsKey(id)
          ?  Token(line, keywords[id], id)
          :  Token(line, TokenKind.TOKEN_IDENTIFIER, id);
    }

    return error("unexpected symbol near ${chunk.current}");
  }

  void skipWhiteSpaces() {
    while (chunk.length > 0) {
      if (chunk.startsWith("--")) {
        skipComment();
      } else if (chunk.startsWith("\r\n") || chunk.startsWith("\n\r")) {
        chunk.next(2);
        line += 1;
      } else if (CharSequence.isNewLine(chunk.current)) {
        chunk.next(1);
        line += 1;
      } else if(CharSequence.isWhiteSpace(chunk.current)) {
        chunk.next(1);
      } else {
        break;
      }
    }
  }

  // ── Tuned hot path ──────────────────────────────────────────────
  // Differences from [nextToken] / [skipWhiteSpaces]:
  //   • switch on `currentCode` (int) instead of `current` (String).
  //     Dart compiles int switches with dense cases to a jump table.
  //   • No 1-char String allocations per character check.
  //   • Keyword lookup is one map read, not two.
  //   • `startsWithCodes2` / `startsWithCodes3` dodge the general
  //     String.startsWith scan for fixed 2–3-char prefixes.
  Token _nextTokenFast() {
    if (cachedNextToken != null) {
      final Token token = cachedNextToken!;
      cachedNextToken = null;
      return token;
    }

    _skipWhiteSpacesFast();
    if (chunk.length <= 0) {
      return Token(line, TokenKind.TOKEN_EOF, "EOF");
    }

    _buff.clear();
    final int code = chunk.currentCode;
    switch (code) {
      case _chSemi:    chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_SEMI,   ";");
      case _chComma:   chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_COMMA,  ",");
      case _chLParen:  chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_LPAREN, "(");
      case _chRParen:  chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_RPAREN, ")");
      case _chRBrack:  chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_RBRACK, "]");
      case _chLCurly:  chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_LCURLY, "{");
      case _chRCurly:  chunk.next(1); return Token(line, TokenKind.TOKEN_SEP_RCURLY, "}");
      case _chPlus:    chunk.next(1); return Token(line, TokenKind.TOKEN_OP_ADD,     "+");
      case _chMinus:   chunk.next(1); return Token(line, TokenKind.TOKEN_OP_MINUS,   "-");
      case _chStar:    chunk.next(1); return Token(line, TokenKind.TOKEN_OP_MUL,     "*");
      case _chCaret:   chunk.next(1); return Token(line, TokenKind.TOKEN_OP_POW,     "^");
      case _chPercent: chunk.next(1); return Token(line, TokenKind.TOKEN_OP_MOD,     "%");
      case _chAmp:     chunk.next(1); return Token(line, TokenKind.TOKEN_OP_BAND,    "&");
      case _chPipe:    chunk.next(1); return Token(line, TokenKind.TOKEN_OP_BOR,     "|");
      case _chHash:    chunk.next(1); return Token(line, TokenKind.TOKEN_OP_LEN,     "#");
      case _chColon:
        if (chunk.codeAt(1) == _chColon) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_SEP_LABEL, "::");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_SEP_COLON, ":");
      case _chSlash:
        if (chunk.codeAt(1) == _chSlash) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_IDIV, "//");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_OP_DIV, "/");
      case _chTilde:
        if (chunk.codeAt(1) == _chEq) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_NE, "~=");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_OP_WAVE, "~");
      case _chEq:
        if (chunk.codeAt(1) == _chEq) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_EQ, "==");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_OP_ASSIGN, "=");
      case _chLt:
        final c1 = chunk.codeAt(1);
        if (c1 == _chLt) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_SHL, "<<");
        }
        if (c1 == _chEq) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_LE, "<=");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_OP_LT, "<");
      case _chGt:
        final c1 = chunk.codeAt(1);
        if (c1 == _chGt) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_SHR, ">>");
        }
        if (c1 == _chEq) {
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_GE, ">=");
        }
        chunk.next(1);
        return Token(line, TokenKind.TOKEN_OP_GT, ">");
      case _chDot:
        final c1 = chunk.codeAt(1);
        if (c1 == _chDot) {
          if (chunk.codeAt(2) == _chDot) {
            chunk.next(3);
            return Token(line, TokenKind.TOKEN_VARARG, "...");
          }
          chunk.next(2);
          return Token(line, TokenKind.TOKEN_OP_CONCAT, "..");
        }
        if (!CharSequence.isDigitCode(c1)) {
          chunk.next(1);
          return Token(line, TokenKind.TOKEN_SEP_DOT, ".");
        }
        // ".123" — fall through to numeric read.
        return Token(line, TokenKind.TOKEN_NUMBER, readNumeral());
      case _chLBrack: {
        final int sep = _skip_sep();
        if (sep >= 0) {
          return Token(line, TokenKind.TOKEN_STRING, readLongString(true, sep));
        }
        if (sep == -1) {
          return Token(line, TokenKind.TOKEN_SEP_LBRACK, "[");
        }
        error("invalid long string delimiter");
        break;
      }
      case _chApos:
      case _chQuote:
        return Token(line, TokenKind.TOKEN_STRING, readString());
    }

    if (CharSequence.isDigitCode(code)) {
      return Token(line, TokenKind.TOKEN_NUMBER, _readNumeralFast());
    }

    if (code == _chUnderscore || CharSequence.isLetterCode(code)) {
      // Identifiers are one contiguous run of [A-Za-z0-9_]. Grab the
      // whole run in a single `sliceFrom` instead of char-by-char
      // StringBuffer writes. Identifier tokens are by far the most
      // common and this was ~16% self-time in the tuned profile.
      final int start = chunk.position;
      chunk.next(1);
      while (true) {
        final int c = chunk.currentCode;
        if (CharSequence.isAlnumCode(c) || c == _chUnderscore) {
          chunk.next(1);
        } else {
          break;
        }
      }
      final String id = chunk.sliceFrom(start);
      // Single-lookup keyword: was `containsKey + []`, now one `[]` read
      // with null-coalesce.
      final TokenKind? kw = keywords[id];
      if (kw != null) return Token(line, kw, id);
      return Token(line, TokenKind.TOKEN_IDENTIFIER, id);
    }

    return error("unexpected symbol near ${chunk.current}");
  }

  /// Tuned numeric literal reader: single `sliceFrom` instead of
  /// StringBuffer char-by-char accumulation. Semantics match
  /// [readNumeral] exactly.
  String _readNumeralFast() {
    final int start = chunk.position;
    int expo1 = 69;  // 'E'
    int expo2 = 101; // 'e'
    final int first = chunk.currentCode;
    chunk.next(1);
    final int second = chunk.currentCode;
    if (first == 48 /* '0' */ && (second == 120 /* 'x' */ || second == 88 /* 'X' */)) {
      expo1 = 80;  // 'P'
      expo2 = 112; // 'p'
      chunk.next(1);
    }
    while (true) {
      final int c = chunk.currentCode;
      if (c == expo1 || c == expo2) {
        chunk.next(1);
        final int sign = chunk.currentCode;
        if (sign == _chMinus || sign == _chPlus) chunk.next(1);
      } else if (CharSequence.isHexDigitCode(c) || c == _chDot) {
        chunk.next(1);
      } else {
        break;
      }
    }
    return chunk.sliceFrom(start);
  }

  void _skipWhiteSpacesFast() {
    while (chunk.length > 0) {
      final int c0 = chunk.currentCode;
      if (c0 == _chMinus && chunk.codeAt(1) == _chMinus) {
        skipComment();
        continue;
      }
      if (c0 == _chCR || c0 == _chLF) {
        final int c1 = chunk.codeAt(1);
        if ((c0 == _chCR && c1 == _chLF) ||
            (c0 == _chLF && c1 == _chCR)) {
          chunk.next(2);
        } else {
          chunk.next(1);
        }
        line += 1;
        continue;
      }
      if (CharSequence.isWhiteSpaceCode(c0)) {
        chunk.next(1);
        continue;
      }
      break;
    }
  }

  void skipComment() {
    chunk.next(2); // skip --

    // long comment ?
    if (chunk.startsWith("[")) {
      int sep = _skip_sep();
      _buff.clear(); /* `skip_sep' 可能会弄脏缓冲区 */
      if (sep >= 0) {
        readLongString(false, sep);  /* long comment */
        _buff.clear();
        return;
      }
    }

    // short comment
    while(chunk.length > 0 && !CharSequence.isNewLine(chunk.current)) {
      chunk.next(1);
    }
  }

  void _save() {
    _buff.write(chunk.current);
  }

  void _save_c(int c) {
    _buff.writeCharCode(c);
  }

  void _save_and_next(){
    _save();
    chunk.next(1);
  }

  void _incLineNumber() {
    String old = chunk.current;
    chunk.next(1); // skip '\n' or '\r'
    if (CharSequence.isNewLine(chunk.current) && chunk.current != old) {
      chunk.next(1); // skip '\n\r' or '\r\n'
    }
    if (++line < 0) { // overflow
      error("chunk has too many lines");
    }
  }

  /// Flush buffered \xXX / \ddd bytes into [_buff], decoding them as
  /// UTF-8 when possible.  Falls back to writing raw char codes (the
  /// previous behaviour) when the bytes are not valid UTF-8.
  void _flushPendingBytes(List<int> pending) {
    if (pending.isEmpty) return;
    try {
      _buff.write(utf8.decode(pending));
    } catch (_) {
      for (var b in pending) {
        _buff.writeCharCode(b);
      }
    }
    pending.clear();
  }

  String readString() {
    // Accumulator for consecutive \xXX and \ddd byte escapes so that
    // multi-byte UTF-8 sequences (e.g. "\xc2\xb7" → U+00B7) are decoded
    // into proper Dart characters instead of being stored per-byte.
    final pendingBytes = <int>[];

    String del = chunk.current;
    _save_and_next();
    while (chunk.current != del) {
      switch (chunk.current) {
        // EOZ
        case '': error("unfinished string"); break;
        case '\n':
        case '\r':
          error("unfinished string");
          continue;
        case '\\':
        {
            late int c;
            // do not save the '\'
            chunk.next(1);
            switch (chunk.current) {
              case 'a':
                c = 7;  // '\a'
                break;
              case 'b':
                c = 8;  // '\b'
                break;
              case 'f':
                c = 12; // '\f'
                break;
              case 'n':
                c = 10; // '\n'
                break;
              case 'r':
                c = 13; // '\r'
                break;
              case 't':
                c = 9;  // '\t'
                break;
              case 'v':
                c = 11; // '\v'
                break;
              case 'x': // '\xXX'
                var hex = chunk.substring(1, 3);
                if(CharSequence.isxDigit(hex)){
                  pendingBytes.add(int.parse(hex, radix: 16));
                  chunk.next(3);
                  continue;
                }else {
                  error("hexadecimal digit expected");
                }
                break;
              case 'u': // '\u{XXX}'
                _flushPendingBytes(pendingBytes);
                chunk.next(1);
                if(chunk.current != '{') error("missing '{'");

                int j = 1;
                while(CharSequence.isxDigit(chunk.charAt(j))) {
                  j++;
                }

                if(chunk.charAt(j) != '}') error("missing '}'");
                var seq = chunk.substring(1, j);
                int d = int.parse(seq, radix: 16);
                if (d <= 0x10FFFF) {
                  _save_c(d);
                  chunk.next(j+1);
                }else {
                  error("UTF-8 value too large near '$seq'");
                }
                continue;
              case '\n': case '\r':
                _flushPendingBytes(pendingBytes);
                _save_c(10); // write '\n'
                _incLineNumber();
                continue;
              case '\\': case '"': case '\'':
                _flushPendingBytes(pendingBytes);
                _save_and_next();
                continue;
              case '': // EOZ
                continue; // will raise an error next loop
              case 'z':    // zap following span of spaces
                _flushPendingBytes(pendingBytes);
                chunk.next(1);
                while (chunk.length > 0 &&
                    CharSequence.isWhiteSpace(chunk.current)) {
                  if(CharSequence.isNewLine(chunk.current)) {
                    _incLineNumber();
                  } else {
                    chunk.next(1);
                  }
                }
                continue;
              default:
                if (!CharSequence.isDigit(chunk.current)) {
                  error("invalid escape sequence near '\\${chunk.current}'");
                } else {  // digital escape '\ddd'
                  int d = 0;
                  /* 最多读取3位数字 */
                  for (int i = 0; i < 3 && CharSequence.isDigit(chunk.current); i++) {
                    d = d * 10 + chunk.current.codeUnitAt(0) - 48 as int;
                    chunk.next(1);
                  }
                  pendingBytes.add(d);
                }
                continue;
            }
            _flushPendingBytes(pendingBytes);
            _save_c(c);
            chunk.next(1);
            continue;
          }
        default:
          _flushPendingBytes(pendingBytes);
          _save_and_next();
      }
    }
    _flushPendingBytes(pendingBytes);
    _save_and_next(); // 跳过分隔符
    var rawToken = _buff.toString();
    return rawToken.substring(1, rawToken.length - 1);
  }

  String readLongString(bool isString, int sep) {
    _save_and_next(); /* skip 2nd `[' */
    if (CharSequence.isNewLine(chunk.current)) {
      /* string starts with a newline? */
      _incLineNumber();
    }
    /* skip it */
    loop:
    for (;;) {
      switch (chunk.current) {
        case '':
          error(
              isString ? "unfinished long string" : "unfinished long comment");
          break;
        case ']':
          if (_skip_sep() == sep) {
            _save_and_next(); /* skip 2nd `]' */
            break loop;
          }
          break;

        case '\n':
        case '\r':
          _save_c(10); // write '\n'
          _incLineNumber();
          if (!isString) _buff.clear();
          break;
        default:
          if (isString) {
            _save_and_next();
          } else {
            chunk.next(1);
          }
      }
    }
    /* loop */
    if (isString) {
      var rawToken = _buff.toString();
      int trim_by = 2 + sep;
      return rawToken.substring(trim_by, rawToken.length - trim_by);
    } else {
      return '';
    }
  }

  int _skip_sep() {
    int count = 0;
    String s = chunk.current;
    // assert(s == '[' || s == ']') ;
    _save_and_next();
    while (chunk.current == '=') {
      _save_and_next();
      count++;
    }
    return (chunk.current == s) ? count : (-count) - 1;
  }

  String readNumeral() {
    String expo1 = 'E';
    String expo2 = 'e';
    String first = chunk.current;
    _save_and_next();
    if (first == '0' && (chunk.current == 'x' || chunk.current == 'X')) {
      expo1 = 'P';
      expo2 = 'p';
      _save_and_next(); // consume 'x' or 'X'
    }

    for (;;) {
      if (chunk.current == expo1 || chunk.current == expo2) {
        _save_and_next(); // consume exponent char
        // optional exponent sign
        if (chunk.current == '-' || chunk.current == '+') {
          _save_and_next();
        }
      } else if (CharSequence.isxDigit(chunk.current) || chunk.current == '.') {
        _save_and_next();
      } else {
        break;
      }
    }
    return _buff.toString();
  }

  int? _line() {
    return cachedNextToken != null ? lineBackup : line;
  }

  error(String msg) {
    throw Exception("$chunkName:${_line()}: $msg");
  }
}
