import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/lua_parser.dart';
import 'package:test/test.dart';

LocalVarDeclStat _decl(String code) =>
    Parser.parse(code, 'test').stats.whereType<LocalVarDeclStat>().first;

void main() {
  group('local attributes (Lua 5.4)', () {
    test('parse into attribList', () {
      expect(_decl('local x <const> = 1').attribList, [LocalAttrib.const_]);
      expect(_decl('local f <close> = nil').attribList, [LocalAttrib.close]);
      final d = _decl('local a, b <const>, c <close> = 1, 2, nil');
      expect(d.nameList, ['a', 'b', 'c']);
      expect(d.attribList, [null, LocalAttrib.const_, LocalAttrib.close]);
      expect(d.expList, hasLength(3));
    });

    test('no attributes: attribList is null', () {
      expect(_decl('local a, b = 1, 2').attribList, isNull);
      expect(_decl('local a').attribList, isNull);
    });

    test('a comparison after a local is not an attribute', () {
      final block = Parser.parse('local a = 1 < 2', 'test');
      expect(
        block.stats.whereType<LocalVarDeclStat>().first.attribList,
        isNull,
      );
    });

    test('invalid attributes fail, as in Lua 5.4', () {
      for (final code in [
        'local x <foo> = 1',
        'local x <const = 1',
        'local x <> = 1',
        'local a <close>, b <close> = nil, nil',
      ]) {
        expect(() => Parser.parse(code, 'test'), throwsException, reason: code);
      }
    });

    test('the Lua 5.3 VM refuses them', () {
      final ls = LuaState.newState()..openLibs();
      expect(() => ls.doString('local x <const> = 1'), throwsException);
      expect(() => ls.doString('local x = 1 return x'), returnsNormally);
    });
  });
}
