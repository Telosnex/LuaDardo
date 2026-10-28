class CharSequence {
  final String _str;
  int _pos;
  // Cached _str.length — read on every `length` / `currentCode` /
  // `codeAt` call. The underlying String.length getter is O(1) but still
  // a method call; caching it shaves a real percentage off the lexer.
  final int _len;

  CharSequence(this._str)
      : _pos = 0,
        _len = _str.length;

  // ── Zero-allocation int API ──────────────────────────────────
  // `chunk.current` / `charAt(i)` return a 1-character String — each
  // call allocates. The hot path in Lexer.nextToken calls these
  // thousands of times per parse. The code-unit variants below return
  // the UTF-16 int directly: zero allocation, and let switch statements
  // compile to jump tables.

  /// Absolute position within the underlying source string. Paired with
  /// [sliceFrom] so callers can grab a contiguous run (identifier,
  /// number) in one `String.substring` call instead of accumulating into
  /// a StringBuffer char by char.
  int get position => _pos;

  /// Slice of the underlying source from [start] (inclusive) to the
  /// current position (exclusive). No copy is made beyond the single
  /// `String.substring` allocation.
  String sliceFrom(int start) => _str.substring(start, _pos);

  /// UTF-16 code unit at the current position, or 0 at EOF.
  int get currentCode => _pos < _len ? _str.codeUnitAt(_pos) : 0;

  /// UTF-16 code unit at current + offset, or 0 at EOF.
  int codeAt(int offset) {
    final i = _pos + offset;
    return i < _len ? _str.codeUnitAt(i) : 0;
  }

  /// Fast `startsWith` for a single ASCII code unit pair. Avoids the
  /// general-purpose String.startsWith scan.
  bool startsWithCodes2(int c0, int c1) {
    if (_pos + 1 >= _len) return false;
    return _str.codeUnitAt(_pos) == c0 && _str.codeUnitAt(_pos + 1) == c1;
  }

  /// Fast `startsWith` for three ASCII code units.
  bool startsWithCodes3(int c0, int c1, int c2) {
    if (_pos + 2 >= _len) return false;
    return _str.codeUnitAt(_pos) == c0 &&
        _str.codeUnitAt(_pos + 1) == c1 &&
        _str.codeUnitAt(_pos + 2) == c2;
  }

  // ── Character-class predicates on raw int code units ─────────────
  // These are the hot-path counterparts to the String-based helpers
  // below. They don't do `c.codeUnitAt(0)` (saves allocation + call).

  static bool isDigitCode(int code) => code >= 48 && code <= 57;

  static bool isLetterCode(int code) =>
      (code >= 97 && code <= 122) || (code >= 65 && code <= 90);

  static bool isAlnumCode(int code) =>
      (code >= 48 && code <= 57) ||
      (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90);

  static bool isWhiteSpaceCode(int code) {
    // \t, \n, \v, \f, \r, space
    return code == 32 || (code >= 9 && code <= 13);
  }

  static bool isNewLineCode(int code) => code == 10 || code == 13;

  static bool isHexDigitCode(int code) =>
      (code >= 48 && code <= 57) ||
      (code >= 97 && code <= 102) ||
      (code >= 65 && code <= 70);

  @override
  String toString() {
    return _str;
  }

  String nextChar() {
    return _str[_pos++];
  }

  // 跳过n个字符
  void next(int n) {
    _pos += n;
  }

  bool startsWith(String prefix) {
    return _str.startsWith(prefix, _pos);
  }

  int indexOf(String s) {
    return _str.indexOf(s, _pos) - _pos;
  }

  String substring(int beginIndex, int endIndex) {
    return _str.substring(beginIndex + _pos, endIndex + _pos);
  }

  int get length => _len - _pos;

  String charAt(int index) {
    int i = index + _pos;
    if (i >= _str.length) return '';
    return _str[i];
  }

  get current {
    return charAt(0);
  }

  // 是否是空白字符
  static bool isWhiteSpace(String c) {
    switch (c.codeUnitAt(0)) {
      case 9: // '\t'
      case 10: // '\n'
      case 11: // '\v'
      case 12: // '\f'
      case 13: // '\r'
      case 32: // ' '
        return true;
    }
    return false;
  }

  static bool isNewLine(String c) {
    return c == '\r' || c == '\n';
  }

  static bool isDigit(String c) {
    var code = c.codeUnitAt(0);
    // '0'~'9'
    return code >= 48 && code <= 57;
  }

  static bool isxDigit(String s) {
    return int.tryParse(s, radix: 16) != null;
  }

  static bool isLetter(String c) {
    var code = c.codeUnitAt(0);
    // a~z and A~Z
    return code >= 97 && code <= 122 || code >= 65 && code <= 90;
  }

  static bool isalnum(String c) {
    if (c.isEmpty) return false;
    var code = c.codeUnitAt(0);
    // '0'~'9' or a~z or A~Z
    return code >= 48 && code <= 57 ||
        code >= 97 && code <= 122 ||
        code >= 65 && code <= 90;
  }

  static int count(String src, String ch) {
    if (src.isEmpty) return 0;

    var sum = 0;
    var len = src.length;
    for (var i = 0; i < len; i++) {
      if (src[i] == ch) sum++;
    }
    return sum;
  }
}
