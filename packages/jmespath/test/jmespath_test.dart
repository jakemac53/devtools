// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:jmespath/jmespath.dart';
import 'package:test/test.dart';

void main() {
  group('search', () {
    test('evaluates basic expressions', () {
      final data = {
        'people': [
          {'name': 'a', 'age': 30},
          {'name': 'b', 'age': 20},
          {'name': 'c', 'age': 40},
        ],
      };
      expect(search('people[0].name', data), 'a');
      expect(search('people[?age > `25`].name', data), ['a', 'c']);
      expect(search('sort_by(people, &age)[].name', data), ['b', 'a', 'c']);
      expect(search('max_by(people, &age).name', data), 'c');
      expect(search('{names: people[].name, count: length(people)}', data), {
        'names': ['a', 'b', 'c'],
        'count': 3,
      });
      expect(search('people[-1:].age | [0]', data), 40);
      expect(search('missing.field', data), isNull);
    });

    test('accepts maps with non-String type arguments', () {
      final data = <dynamic, dynamic>{
        'a': <dynamic>[1, 2, 3],
      };
      expect(search('a[1]', data), 2);
      expect(search('keys(@)', data), ['a']);
    });
  });

  group('compile', () {
    test('can be evaluated multiple times', () {
      final expression = compile('foo.bar');
      expect(expression.expression, 'foo.bar');
      expect(
        expression.search({
          'foo': {'bar': 1},
        }),
        1,
      );
      expect(
        expression.search({
          'foo': {'bar': 2},
        }),
        2,
      );
      expect(expression.search(null), isNull);
    });

    test('reports syntax errors eagerly', () {
      expect(
        () => compile('foo.'),
        throwsA(isA<JmesPathSyntaxException>()),
      );
      expect(
        () => compile('foo[?'),
        throwsA(isA<JmesPathSyntaxException>()),
      );
    });

    test('reports unknown functions and arity errors eagerly', () {
      expect(
        () => compile('nope(@)'),
        throwsA(isA<JmesPathUnknownFunctionException>()),
      );
      expect(
        () => compile('length(@, @)'),
        throwsA(isA<JmesPathInvalidArityException>()),
      );
    });
  });

  group('exceptions', () {
    test('have types matching the compliance suite', () {
      expect(JmesPathErrorType.syntax.id, 'syntax');
      expect(JmesPathErrorType.invalidType.id, 'invalid-type');
      expect(JmesPathErrorType.invalidValue.id, 'invalid-value');
      expect(JmesPathErrorType.invalidArity.id, 'invalid-arity');
      expect(JmesPathErrorType.unknownFunction.id, 'unknown-function');
    });

    test('syntax errors point at the offending location', () {
      try {
        search('foo.[bar', null);
        fail('Expected an exception');
      } on JmesPathSyntaxException catch (e) {
        expect(e.type, JmesPathErrorType.syntax);
        expect(e.expression, 'foo.[bar');
        expect(e.offset, 8);
        expect(e.toString(), contains('foo.[bar\n        ^'));
      }
    });

    test('invalid types are reported at evaluation time', () {
      final expression = compile('abs(@)');
      expect(expression.search(-1), 1);
      expect(
        () => expression.search('x'),
        throwsA(isA<JmesPathInvalidTypeException>()),
      );
    });
  });

  group('custom functions', () {
    final functions = {
      'upper': JmesPathFunction([
        {JmesPathType.string},
      ], (args) => (args[0] as String).toUpperCase()),
      'format_bytes': JmesPathFunction([
        {JmesPathType.number},
      ], (args) => '${((args[0] as num) / 1024).toStringAsFixed(1)} KB'),
      'concat': JmesPathFunction(
        [
          {JmesPathType.string},
        ],
        (args) => args.cast<String>().join(),
        variadic: true,
      ),
      'apply': JmesPathFunction(
        [
          {JmesPathType.expressionReference},
          {JmesPathType.any},
        ],
        (args) => (args[0] as ExpressionReference).evaluate(args[1]),
      ),
      // Overrides the built-in function.
      'length': JmesPathFunction([
        {JmesPathType.any},
      ], (args) => -1),
    };

    test('can be called', () {
      final data = {
        'name': 'dash',
        'sizes': [1024, 2048],
      };
      expect(search('upper(name)', data, functions: functions), 'DASH');
      expect(search('sizes[].format_bytes(@)', data, functions: functions), [
        '1.0 KB',
        '2.0 KB',
      ]);
      expect(
        search("concat(name, '-', upper(name))", data, functions: functions),
        'dash-DASH',
      );
      expect(search('apply(&name, @)', data, functions: functions), 'dash');
    });

    test('can override built-in functions', () {
      expect(search('length(@)', [1, 2], functions: functions), -1);
      expect(search('length(@)', [1, 2]), 2);
    });

    test('have their arguments validated', () {
      expect(
        () => search('upper(`1`)', null, functions: functions),
        throwsA(isA<JmesPathInvalidTypeException>()),
      );
      expect(
        () => search('upper()', null, functions: functions),
        throwsA(isA<JmesPathInvalidArityException>()),
      );
      expect(
        () => search('concat()', null, functions: functions),
        throwsA(isA<JmesPathInvalidArityException>()),
      );
    });
  });

  group('built-in functions', () {
    test('sort and sort_by use code point order and are stable', () {
      // U+FF21 (fullwidth A) sorts before U+1F600 (an emoji encoded as a
      // surrogate pair), even though its UTF-16 code unit is larger.
      expect(search('sort(@)', ['\u{1F600}', '\uFF21', 'a']), [
        'a',
        '\uFF21',
        '\u{1F600}',
      ]);
      final items = [
        for (var i = 0; i < 20; i++) {'key': i % 2, 'i': i},
      ];
      expect(search('sort_by(@, &key)[].i', items), [
        for (var i = 0; i < 20; i += 2) i,
        for (var i = 1; i < 20; i += 2) i,
      ]);
    });

    test('length and reverse operate on code points', () {
      expect(search('length(@)', 'a\u{1F600}b'), 3);
      expect(search('reverse(@)', 'a\u{1F600}b'), 'b\u{1F600}a');
    });

    test('to_number parses numbers', () {
      expect(search("to_number('42')", null), 42);
      expect(search("to_number('-1.5')", null), -1.5);
      expect(search("to_number('1e3')", null), 1000);
      expect(search("to_number('abc')", null), isNull);
      expect(search("to_number('')", null), isNull);
    });
  });

  group('jsonEquals', () {
    test('compares deeply', () {
      expect(jsonEquals(1, 1.0), isTrue);
      expect(jsonEquals(1, true), isFalse);
      expect(
          jsonEquals({
            'a': [1, 2]
          }, {
            'a': [1, 2]
          }),
          isTrue);
      expect(
          jsonEquals({
            'a': [1, 2]
          }, {
            'a': [2, 1]
          }),
          isFalse);
      expect(jsonEquals({'a': null}, <String, Object?>{}), isFalse);
    });
  });
}
