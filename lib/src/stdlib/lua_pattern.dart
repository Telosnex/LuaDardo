/// Port of reference Lua 5.3's string pattern matcher (lstrlib.c).
///
/// Supports the full Lua 5.3 pattern syntax, including `%b` balanced matches
/// and `%f[set]` frontier patterns, which the prior RegExp-based translator
/// could not express. Operates on Dart String code units treating them as
/// bytes (matching reference Lua's byte-oriented semantics for ASCII; for
/// BMP text this is equivalent to per-char).
library;

/// Raised for malformed patterns (`ends with '%'`, missing `]`, etc.) or
/// resource limits (too many captures, pattern too complex).
class LuaPatternError implements Exception {
  final String message;
  LuaPatternError(this.message);
  @override
  String toString() => message;
}

/// A single capture from a successful match. Either a substring (normal
/// `()` capture) or a 1-based byte position (empty `()` position capture).
sealed class LuaCapture {
  const LuaCapture();
}

class StringCapture extends LuaCapture {
  final String value;
  const StringCapture(this.value);
  @override
  String toString() => 'StringCapture($value)';
}

class PositionCapture extends LuaCapture {
  /// 1-based index into the source string, per Lua semantics.
  final int position;
  const PositionCapture(this.position);
  @override
  String toString() => 'PositionCapture($position)';
}

/// Result of a successful pattern match.
class LuaPatternMatch {
  /// 0-based index where the whole match starts.
  final int start;

  /// 0-based exclusive index where the whole match ends.
  final int end;

  /// Captured groups, in pattern order.
  final List<LuaCapture> captures;

  const LuaPatternMatch(this.start, this.end, this.captures);

  /// Returns the captures as plain Dart values (String for string captures,
  /// int for position captures). Convenient for callers that don't care
  /// about the distinction.
  List<Object> get captureValues => [
        for (final c in captures)
          if (c is StringCapture) c.value else (c as PositionCapture).position,
      ];
}

class LuaPattern {
  static const int _lMaxCaptures = 32;
  static const int _maxMatchDepth = 200;
  static const int _capUnfinished = -1;
  static const int _capPosition = -2;

  // --- ASCII character class helpers (match C's ctype.h semantics) ---

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
  static bool _isAlpha(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  static bool _isAlnum(int c) => _isAlpha(c) || _isDigit(c);
  static bool _isLower(int c) => c >= 0x61 && c <= 0x7A;
  static bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;
  static bool _isSpace(int c) =>
      c == 0x20 || // space
      c == 0x09 || // \t
      c == 0x0A || // \n
      c == 0x0B || // \v
      c == 0x0C || // \f
      c == 0x0D; // \r
  static bool _isCntrl(int c) => c < 0x20 || c == 0x7F;
  static bool _isXdigit(int c) =>
      _isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
  static bool _isGraph(int c) => c > 0x20 && c < 0x7F;
  static bool _isPunct(int c) => _isGraph(c) && !_isAlnum(c);

  /// `match_class` from lstrlib.c: does byte [c] belong to class letter [cl]?
  /// Uppercase class letters negate.
  static bool _matchClass(int c, int cl) {
    final lowered = cl | 0x20; // tolower for ASCII letters
    bool res;
    switch (lowered) {
      case 0x61: // 'a'
        res = _isAlpha(c);
        break;
      case 0x63: // 'c'
        res = _isCntrl(c);
        break;
      case 0x64: // 'd'
        res = _isDigit(c);
        break;
      case 0x67: // 'g'
        res = _isGraph(c);
        break;
      case 0x6C: // 'l'
        res = _isLower(c);
        break;
      case 0x70: // 'p'
        res = _isPunct(c);
        break;
      case 0x73: // 's'
        res = _isSpace(c);
        break;
      case 0x75: // 'u'
        res = _isUpper(c);
        break;
      case 0x77: // 'w'
        res = _isAlnum(c);
        break;
      case 0x78: // 'x'
        res = _isXdigit(c);
        break;
      default:
        return cl == c; // non-class-letter escape: literal match
    }
    if (_isUpper(cl)) res = !res;
    return res;
  }

  // --- Pattern entry points -------------------------------------------------

  /// Find the first match of [pattern] in [s] starting at 0-based byte index
  /// [init]. If [pattern] starts with `^`, the match is only attempted at
  /// [init]. Returns `null` on no match.
  static LuaPatternMatch? match(String s, String pattern, [int init = 0]) {
    if (init < 0) init = 0;
    if (init > s.length) return null;

    final anchored = pattern.isNotEmpty && pattern.codeUnitAt(0) == 0x5E;
    final pStart = anchored ? 1 : 0;
    final ms = _MatchState(s, pattern);

    var sIdx = init;
    while (true) {
      ms.captures.clear();
      ms.matchDepth = _maxMatchDepth;
      final end = _match(ms, sIdx, pStart);
      if (end != null) {
        return LuaPatternMatch(sIdx, end, _extractCaptures(ms, s));
      }
      if (anchored) return null;
      sIdx++;
      if (sIdx > s.length) return null;
    }
  }

  /// Iterate all non-overlapping matches, advancing past each match (or by
  /// one byte if the match was empty, matching reference Lua's gmatch loop).
  static Iterable<LuaPatternMatch> allMatches(String s, String pattern) sync* {
    // gmatch ignores a leading '^' anchor per reference Lua: it "tries to
    // match the pattern anywhere in s", but the ^ would make every iteration
    // after the first fail. To match upstream, we just run the normal engine;
    // if anchored, only the very first attempt (at sIdx = 0) can succeed.
    final anchored = pattern.isNotEmpty && pattern.codeUnitAt(0) == 0x5E;
    var init = 0;
    while (init <= s.length) {
      final m = match(s, pattern, init);
      if (m == null) return;
      yield m;
      if (anchored) return;
      if (m.end > m.start) {
        init = m.end;
      } else {
        init = m.start + 1;
      }
    }
  }

  static List<LuaCapture> _extractCaptures(_MatchState ms, String src) {
    final result = <LuaCapture>[];
    for (final c in ms.captures) {
      if (c.len == _capPosition) {
        result.add(PositionCapture(c.init + 1));
      } else if (c.len >= 0) {
        result.add(StringCapture(src.substring(c.init, c.init + c.len)));
      } else {
        throw LuaPatternError('invalid capture index');
      }
    }
    return result;
  }

  // --- Match engine (ported from lstrlib.c) ---------------------------------

  /// The `match` function: return the index in [ms.src] one past the last
  /// byte consumed by pattern starting at [pIdx], or `null` on failure.
  static int? _match(_MatchState ms, int sIdx, int pIdx) {
    if (ms.matchDepth-- == 0) {
      throw LuaPatternError('pattern too complex');
    }
    try {
      // Translate the `goto dispatch` loop from C. Most branches `return`
      // immediately; `goto dispatch` branches update sIdx/pIdx and `continue`.
      while (true) {
        if (pIdx >= ms.pEnd) {
          // Matched everything — success.
          return sIdx;
        }
        final pc = ms.pat.codeUnitAt(pIdx);

        // Start-capture.
        if (pc == 0x28 /* '(' */) {
          if (pIdx + 1 < ms.pEnd && ms.pat.codeUnitAt(pIdx + 1) == 0x29) {
            return _startCapture(ms, sIdx, pIdx + 2, _capPosition);
          }
          return _startCapture(ms, sIdx, pIdx + 1, _capUnfinished);
        }
        // End-capture.
        if (pc == 0x29 /* ')' */) {
          return _endCapture(ms, sIdx, pIdx + 1);
        }
        // End-anchor.
        if (pc == 0x24 /* '$' */ && pIdx + 1 == ms.pEnd) {
          return (sIdx == ms.src.length) ? sIdx : null;
        }
        // %-escape with special follow-up byte.
        if (pc == 0x25 /* '%' */ && pIdx + 1 < ms.pEnd) {
          final nxt = ms.pat.codeUnitAt(pIdx + 1);
          if (nxt == 0x62 /* 'b' */) {
            // Balanced match: %bxy.
            final s = _matchBalance(ms, sIdx, pIdx + 2);
            if (s == null) return null;
            sIdx = s;
            pIdx += 4;
            continue;
          }
          if (nxt == 0x66 /* 'f' */) {
            // Frontier pattern: %f[set].
            pIdx += 2;
            if (pIdx >= ms.pEnd || ms.pat.codeUnitAt(pIdx) != 0x5B) {
              throw LuaPatternError("missing '[' after '%f' in pattern");
            }
            final ep = _classEnd(ms, pIdx); // past ']'
            final prev = (sIdx == 0) ? 0 : ms.src.codeUnitAt(sIdx - 1);
            final curr = (sIdx < ms.src.length) ? ms.src.codeUnitAt(sIdx) : 0;
            if (!_matchBracketClass(prev, ms, pIdx, ep - 1) &&
                _matchBracketClass(curr, ms, pIdx, ep - 1)) {
              pIdx = ep;
              continue;
            }
            return null;
          }
          if (nxt >= 0x30 /* '0' */ && nxt <= 0x39 /* '9' */) {
            // Back-reference: %1..%9. (%0 would underflow → error.)
            final s = _matchCapture(ms, sIdx, nxt - 0x31 /* '1' */);
            if (s == null) return null;
            sIdx = s;
            pIdx += 2;
            continue;
          }
          // Other %x escapes fall through to the default single-char path.
        }

        // --- Default: one pattern item, optionally with ? / + / * / -. ---
        final ep = _classEnd(ms, pIdx); // past the pattern item
        if (_singleMatch(ms, sIdx, pIdx, ep)) {
          if (ep < ms.pEnd) {
            final q = ms.pat.codeUnitAt(ep);
            if (q == 0x3F /* '?' */) {
              final res = _match(ms, sIdx + 1, ep + 1);
              if (res != null) return res;
              pIdx = ep + 1;
              continue;
            }
            if (q == 0x2B /* '+' */) {
              return _maxExpand(ms, sIdx + 1, pIdx, ep);
            }
            if (q == 0x2A /* '*' */) {
              return _maxExpand(ms, sIdx, pIdx, ep);
            }
            if (q == 0x2D /* '-' */) {
              return _minExpand(ms, sIdx, pIdx, ep);
            }
          }
          // No quantifier — consume the byte and keep matching.
          sIdx++;
          pIdx = ep;
          continue;
        }
        // singleMatch failed — but if quantifier allows zero matches,
        // skip the item and retry.
        if (ep < ms.pEnd) {
          final q = ms.pat.codeUnitAt(ep);
          if (q == 0x2A /* '*' */ ||
              q == 0x3F /* '?' */ ||
              q == 0x2D /* '-' */) {
            pIdx = ep + 1;
            continue;
          }
        }
        return null;
      }
    } finally {
      ms.matchDepth++;
    }
  }

  /// Port of `singlematch`: does [ms.src] at [sIdx] satisfy the pattern item
  /// that begins at [pIdx] and ends at [ep]?
  static bool _singleMatch(_MatchState ms, int sIdx, int pIdx, int ep) {
    if (sIdx >= ms.src.length) return false;
    final c = ms.src.codeUnitAt(sIdx);
    final p = ms.pat.codeUnitAt(pIdx);
    switch (p) {
      case 0x2E: // '.'
        return true;
      case 0x25: // '%'
        return _matchClass(c, ms.pat.codeUnitAt(pIdx + 1));
      case 0x5B: // '['
        return _matchBracketClass(c, ms, pIdx, ep - 1);
      default:
        return p == c;
    }
  }

  /// Port of `classend`: given pattern starting at [pIdx], return the index
  /// one past the end of this pattern *item* (e.g. past `]` for `[...]`,
  /// past the second byte for `%x`, or past the single byte otherwise).
  static int _classEnd(_MatchState ms, int pIdx) {
    final p = ms.pat.codeUnitAt(pIdx);
    if (p == 0x25 /* '%' */) {
      if (pIdx + 1 >= ms.pEnd) {
        throw LuaPatternError("malformed pattern (ends with '%')");
      }
      return pIdx + 2;
    }
    if (p == 0x5B /* '[' */) {
      var p2 = pIdx + 1;
      if (p2 < ms.pEnd && ms.pat.codeUnitAt(p2) == 0x5E /* '^' */) p2++;
      // A first `]` or escape is a literal member of the class.
      do {
        if (p2 >= ms.pEnd) {
          throw LuaPatternError("malformed pattern (missing ']')");
        }
        final c = ms.pat.codeUnitAt(p2++);
        if (c == 0x25 /* '%' */ && p2 < ms.pEnd) {
          p2++; // skip escaped character
        }
      } while (p2 < ms.pEnd && ms.pat.codeUnitAt(p2) != 0x5D /* ']' */);
      if (p2 >= ms.pEnd) {
        throw LuaPatternError("malformed pattern (missing ']')");
      }
      return p2 + 1;
    }
    return pIdx + 1;
  }

  /// Port of `matchbracketclass`: is byte [c] in the bracket set that starts
  /// at [pIdx] (on '[') and ends at [ec] (on ']')?
  static bool _matchBracketClass(int c, _MatchState ms, int pIdx, int ec) {
    var p = pIdx + 1;
    bool sig = true;
    if (p < ec && ms.pat.codeUnitAt(p) == 0x5E /* '^' */) {
      sig = false;
      p++;
    }
    while (p < ec) {
      final ch = ms.pat.codeUnitAt(p);
      if (ch == 0x25 /* '%' */ && p + 1 < ec) {
        p++;
        if (_matchClass(c, ms.pat.codeUnitAt(p))) return sig;
        p++;
      } else if (p + 2 < ec && ms.pat.codeUnitAt(p + 1) == 0x2D /* '-' */) {
        final lo = ch;
        final hi = ms.pat.codeUnitAt(p + 2);
        if (lo <= c && c <= hi) return sig;
        p += 3;
      } else {
        if (ch == c) return sig;
        p++;
      }
    }
    return !sig;
  }

  /// Port of `matchbalance`: starting at [sIdx], match an opening byte
  /// (from `ms.pat[pIdx]`) followed by balanced text up to its closing byte
  /// (from `ms.pat[pIdx+1]`). Returns the index after the closing byte, or
  /// `null` on failure.
  static int? _matchBalance(_MatchState ms, int sIdx, int pIdx) {
    if (pIdx + 1 >= ms.pEnd) {
      throw LuaPatternError("malformed pattern (missing arguments to '%b')");
    }
    if (sIdx >= ms.src.length) return null;
    final open = ms.pat.codeUnitAt(pIdx);
    final close = ms.pat.codeUnitAt(pIdx + 1);
    if (ms.src.codeUnitAt(sIdx) != open) return null;
    var depth = 1;
    var s = sIdx + 1;
    while (s < ms.src.length) {
      final c = ms.src.codeUnitAt(s);
      if (c == close) {
        depth--;
        if (depth == 0) return s + 1;
      } else if (c == open) {
        depth++;
      }
      s++;
    }
    return null;
  }

  /// Port of `match_capture`: the back-reference `%N` must equal the
  /// previously-captured substring with index [capIdx].
  static int? _matchCapture(_MatchState ms, int sIdx, int capIdx) {
    if (capIdx < 0 || capIdx >= ms.captures.length) {
      throw LuaPatternError('invalid capture index %${capIdx + 1}');
    }
    final c = ms.captures[capIdx];
    if (c.len < 0) {
      throw LuaPatternError('invalid capture index %${capIdx + 1}');
    }
    final len = c.len;
    if (ms.src.length - sIdx < len) return null;
    for (var i = 0; i < len; i++) {
      if (ms.src.codeUnitAt(c.init + i) != ms.src.codeUnitAt(sIdx + i)) {
        return null;
      }
    }
    return sIdx + len;
  }

  /// Port of `max_expand`: greedy quantifier (`*` or `+`). Try to consume as
  /// many items as possible, then fall back one at a time until the rest of
  /// the pattern matches.
  static int? _maxExpand(_MatchState ms, int sIdx, int pIdx, int ep) {
    var i = 0;
    while (_singleMatch(ms, sIdx + i, pIdx, ep)) {
      i++;
    }
    while (i >= 0) {
      final res = _match(ms, sIdx + i, ep + 1);
      if (res != null) return res;
      i--;
    }
    return null;
  }

  /// Port of `min_expand`: lazy quantifier (`-`). Try to match the rest of
  /// the pattern first; if that fails, consume one item and retry.
  static int? _minExpand(_MatchState ms, int sIdx, int pIdx, int ep) {
    while (true) {
      final res = _match(ms, sIdx, ep + 1);
      if (res != null) return res;
      if (_singleMatch(ms, sIdx, pIdx, ep)) {
        sIdx++;
      } else {
        return null;
      }
    }
  }

  /// Port of `start_capture`: begin a new capture (either an unfinished
  /// substring capture or a zero-width position capture).
  static int? _startCapture(_MatchState ms, int sIdx, int pIdx, int kind) {
    if (ms.captures.length >= _lMaxCaptures) {
      throw LuaPatternError('too many captures');
    }
    ms.captures.add(_Capture(sIdx, kind));
    final res = _match(ms, sIdx, pIdx);
    if (res == null) {
      ms.captures.removeLast();
    }
    return res;
  }

  /// Port of `end_capture`: finalise the most recent unfinished capture with
  /// length `sIdx - init`, then continue matching. On failure, restore the
  /// unfinished state so backtracking can retry.
  static int? _endCapture(_MatchState ms, int sIdx, int pIdx) {
    var l = ms.captures.length - 1;
    while (l >= 0 && ms.captures[l].len != _capUnfinished) {
      l--;
    }
    if (l < 0) {
      throw LuaPatternError('invalid pattern capture');
    }
    final cap = ms.captures[l];
    final saved = cap.len;
    cap.len = sIdx - cap.init;
    final res = _match(ms, sIdx, pIdx);
    if (res == null) {
      cap.len = saved;
    }
    return res;
  }
}

class _MatchState {
  final String src;
  final String pat;
  final int pEnd;
  int matchDepth = LuaPattern._maxMatchDepth;
  final List<_Capture> captures = [];
  _MatchState(this.src, this.pat) : pEnd = pat.length;
}

class _Capture {
  final int init;
  int len; // -1 unfinished, -2 position, else actual length
  _Capture(this.init, this.len);
}
