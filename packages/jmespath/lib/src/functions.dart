// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'exceptions.dart';
import 'values.dart';

/// The types that a [JmesPathFunction] parameter can accept.
enum JmesPathType {
  /// Any value, including `null`.
  any('any'),

  /// A [num] (but not a [bool]).
  number('number'),

  /// A [String].
  string('string'),

  /// A [bool].
  boolean('boolean'),

  /// A [List].
  array('array'),

  /// A [Map].
  object('object'),

  /// `null`.
  nullValue('null'),

  /// An expression reference such as `&foo`, passed to the function body as
  /// an [ExpressionReference].
  expressionReference('expref'),

  /// A [List] whose elements are all numbers.
  arrayOfNumbers('array[number]'),

  /// A [List] whose elements are all strings.
  arrayOfStrings('array[string]');

  const JmesPathType(this.displayName);

  /// The name of this type as used in the JMESPath specification.
  final String displayName;

  /// Whether [value] is an instance of this type.
  bool matches(Object? value) => switch (this) {
        any => true,
        number => value is num,
        string => value is String,
        boolean => value is bool,
        array => value is List,
        object => value is Map,
        nullValue => value == null,
        expressionReference => value is ExpressionReference,
        arrayOfNumbers => value is List && value.every((e) => e is num),
        arrayOfStrings => value is List && value.every((e) => e is String),
      };
}

/// Returns the JMESPath type name of [value], as returned by the `type()`
/// function.
String typeOf(Object? value) => switch (value) {
      null => 'null',
      num() => 'number',
      String() => 'string',
      bool() => 'boolean',
      List() => 'array',
      Map() => 'object',
      ExpressionReference() => 'expref',
      _ => 'unknown',
    };

/// An expression reference (`&expression`) passed as an argument to a
/// function.
abstract interface class ExpressionReference {
  /// Evaluates the referenced expression against [data].
  Object? evaluate(Object? data);
}

/// The signature of the Dart implementation of a [JmesPathFunction].
///
/// The [arguments] have already been validated against the function's
/// [JmesPathFunction.parameters].
typedef JmesPathFunctionBody = Object? Function(List<Object?> arguments);

/// A function that can be called from a JMESPath expression.
///
/// Custom functions can be provided to `search` and `compile`; they take
/// precedence over built-in functions with the same name.
///
/// ```dart
/// final upper = JmesPathFunction(
///   [{JmesPathType.string}],
///   (args) => (args.single as String).toUpperCase(),
/// );
/// search('upper(name)', {'name': 'dash'}, functions: {'upper': upper});
/// ```
final class JmesPathFunction {
  const JmesPathFunction(this.parameters, this.body, {this.variadic = false});

  /// The accepted types for each positional parameter.
  ///
  /// An argument is valid if it matches any of the types in the set.
  final List<Set<JmesPathType>> parameters;

  /// Whether the last parameter may be repeated.
  ///
  /// Variadic functions must be passed at least [parameters].length
  /// arguments; any extra arguments are checked against the last parameter.
  final bool variadic;

  /// The Dart implementation of the function.
  final JmesPathFunctionBody body;

  /// Throws a [JmesPathInvalidArityException] if [count] arguments is not a
  /// valid number of arguments for this function.
  void checkArity(String name, int count) {
    final expected = parameters.length;
    if (variadic ? count < expected : count != expected) {
      final qualifier = variadic ? 'at least ' : '';
      throw JmesPathInvalidArityException(
        '$name() takes $qualifier$expected argument${expected == 1 ? '' : 's'}'
        ' but $count ${count == 1 ? 'was' : 'were'} given',
      );
    }
  }

  /// Validates [arguments] and invokes [body].
  Object? call(String name, List<Object?> arguments) {
    checkArity(name, arguments.length);
    for (var i = 0; i < arguments.length; i++) {
      final types =
          parameters[i < parameters.length ? i : parameters.length - 1];
      final argument = arguments[i];
      if (!types.any((t) => t.matches(argument))) {
        throw JmesPathInvalidTypeException(
          '$name() expected argument ${i + 1} to be of type '
          '${types.map((t) => t.displayName).join('|')} but got '
          '${typeOf(argument)}',
        );
      }
    }
    return body(arguments);
  }
}

const _number = {JmesPathType.number};
const _string = {JmesPathType.string};
const _array = {JmesPathType.array};
const _object = {JmesPathType.object};
const _any = {JmesPathType.any};
const _expref = {JmesPathType.expressionReference};
const _numbersOrStrings = {
  JmesPathType.arrayOfNumbers,
  JmesPathType.arrayOfStrings,
};

/// The built-in functions defined by the JMESPath specification.
final Map<String, JmesPathFunction> builtInFunctions = {
  'abs': JmesPathFunction([_number], (a) => (a[0] as num).abs()),
  'avg': JmesPathFunction([
    {JmesPathType.arrayOfNumbers},
  ], (a) => _avg(a[0] as List)),
  'ceil': JmesPathFunction([_number], (a) => (a[0] as num).ceil()),
  'contains': JmesPathFunction([
    {JmesPathType.array, JmesPathType.string},
    _any,
  ], (a) => _contains(a[0], a[1])),
  'ends_with': JmesPathFunction([
    _string,
    _string,
  ], (a) => (a[0] as String).endsWith(a[1] as String)),
  'floor': JmesPathFunction([_number], (a) => (a[0] as num).floor()),
  'join': JmesPathFunction([
    _string,
    {JmesPathType.arrayOfStrings},
  ], (a) => (a[1] as List).join(a[0] as String)),
  'keys': JmesPathFunction([_object], (a) => (a[0] as Map).keys.toList()),
  'length': JmesPathFunction([
    {JmesPathType.string, JmesPathType.array, JmesPathType.object},
  ], (a) => _length(a[0])),
  'map': JmesPathFunction([_expref, _array], (a) {
    final expression = a[0] as ExpressionReference;
    return [for (final e in a[1] as List) expression.evaluate(e)];
  }),
  'max':
      JmesPathFunction([_numbersOrStrings], (a) => _extreme(a[0] as List, 1)),
  'max_by': JmesPathFunction([
    _array,
    _expref,
  ], (a) => _extremeBy('max_by', a[0] as List, a[1] as ExpressionReference, 1)),
  'merge': JmesPathFunction([_object], (a) {
    return <Object?, Object?>{for (final m in a) ...(m as Map)};
  }, variadic: true),
  'min': JmesPathFunction([
    _numbersOrStrings,
  ], (a) => _extreme(a[0] as List, -1)),
  'min_by': JmesPathFunction(
      [
        _array,
        _expref,
      ],
      (a) =>
          _extremeBy('min_by', a[0] as List, a[1] as ExpressionReference, -1)),
  'not_null': JmesPathFunction(
    [_any],
    (a) => a.firstWhere((e) => e != null, orElse: () => null),
    variadic: true,
  ),
  'reverse': JmesPathFunction([
    {JmesPathType.string, JmesPathType.array},
  ], (a) => _reverse(a[0])),
  'sort': JmesPathFunction([_numbersOrStrings], (a) {
    return (a[0] as List).toList()..sort(_compareSortable);
  }),
  'sort_by': JmesPathFunction([
    _array,
    _expref,
  ], (a) => _sortBy(a[0] as List, a[1] as ExpressionReference)),
  'starts_with': JmesPathFunction([
    _string,
    _string,
  ], (a) => (a[0] as String).startsWith(a[1] as String)),
  'sum': JmesPathFunction([
    {JmesPathType.arrayOfNumbers},
  ], (a) => (a[0] as List).fold<num>(0, (sum, e) => sum + (e as num))),
  'to_array': JmesPathFunction([_any], (a) {
    final value = a[0];
    return value is List ? value : [value];
  }),
  'to_number': JmesPathFunction([_any], (a) => _toNumber(a[0])),
  'to_string': JmesPathFunction([_any], (a) => _toString(a[0])),
  'type': JmesPathFunction([_any], (a) => typeOf(a[0])),
  'values': JmesPathFunction([_object], (a) => (a[0] as Map).values.toList()),
};

Object? _avg(List numbers) {
  if (numbers.isEmpty) return null;
  var sum = 0.0;
  for (final n in numbers) {
    sum += n as num;
  }
  return sum / numbers.length;
}

bool _contains(Object? subject, Object? search) {
  if (subject is String) return search is String && subject.contains(search);
  return (subject as List).any((e) => jsonEquals(e, search));
}

int _length(Object? value) => switch (value) {
      String() => value.runes.length,
      List() => value.length,
      Map() => value.length,
      _ => throw StateError('unreachable'),
    };

Object _reverse(Object? value) => switch (value) {
      String() => String.fromCharCodes(value.runes.toList().reversed),
      List() => value.reversed.toList(),
      _ => throw StateError('unreachable'),
    };

/// Compares two values that are known to both be numbers or both be strings.
int _compareSortable(Object? a, Object? b) {
  if (a is String && b is String) return compareCodePoints(a, b);
  return (a as num).compareTo(b as num);
}

/// Returns the largest ([direction] = 1) or smallest ([direction] = -1)
/// element of [values], or null if it is empty.
Object? _extreme(List values, int direction) {
  if (values.isEmpty) return null;
  var result = values.first;
  for (final value in values.skip(1)) {
    if (_compareSortable(value, result) * direction > 0) result = value;
  }
  return result;
}

/// Evaluates [expression] against each element of [values], checking that
/// the results are all numbers or all strings.
List<Object> _sortKeys(
  String name,
  List values,
  ExpressionReference expression,
) {
  final keys = <Object>[];
  String? keyType;
  for (final value in values) {
    final key = expression.evaluate(value);
    final type = typeOf(key);
    if ((type != 'number' && type != 'string') ||
        (keyType != null && keyType != type)) {
      throw JmesPathInvalidTypeException(
        '$name() expected the expression to return '
        '${keyType ?? 'number|string'} but got $type',
      );
    }
    keyType = type;
    keys.add(key!);
  }
  return keys;
}

Object? _extremeBy(
  String name,
  List values,
  ExpressionReference expression,
  int direction,
) {
  if (values.isEmpty) return null;
  final keys = _sortKeys(name, values, expression);
  var best = 0;
  for (var i = 1; i < values.length; i++) {
    if (_compareSortable(keys[i], keys[best]) * direction > 0) best = i;
  }
  return values[best];
}

List _sortBy(List values, ExpressionReference expression) {
  final keys = _sortKeys('sort_by', values, expression);
  // Sort indices, breaking ties by original position to keep the sort stable.
  final indices = List<int>.generate(values.length, (i) => i)
    ..sort((a, b) {
      final result = _compareSortable(keys[a], keys[b]);
      return result != 0 ? result : a - b;
    });
  return [for (final i in indices) values[i]];
}

final _numberPattern = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

num? _toNumber(Object? value) {
  if (value is num) return value;
  if (value is! String) return null;
  final text = value.trim();
  if (!_numberPattern.hasMatch(text)) return null;
  return int.tryParse(text) ?? double.tryParse(text);
}

String _toString(Object? value) {
  if (value is String) return value;
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    throw JmesPathInvalidTypeException(
      'to_string() cannot convert a value of type ${typeOf(value)}',
    );
  }
}
