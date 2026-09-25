// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'ast.dart';
import 'functions.dart';
import 'interpreter.dart';
import 'parser.dart';

/// Evaluates the JMESPath [expression] against [data] and returns the result.
///
/// [data] should be a JSON-like value: a `Map<String, Object?>`, `List`,
/// `String`, `num`, `bool` or `null`, containing only such values.
///
/// Custom [functions] may be provided, which take precedence over built-in
/// functions of the same name.
///
/// Throws a `JmesPathException` if the expression is invalid or cannot be
/// evaluated against [data].
Object? search(
  String expression,
  Object? data, {
  Map<String, JmesPathFunction>? functions,
}) =>
    compile(expression, functions: functions).search(data);

/// Parses and validates [expression] so that it can be evaluated efficiently
/// many times with [JmesPathExpression.search].
///
/// Custom [functions] may be provided, which take precedence over built-in
/// functions of the same name.
///
/// Throws a `JmesPathException` if the expression is not valid, including if
/// it calls an unknown function or calls a function with the wrong number of
/// arguments.
JmesPathExpression compile(
  String expression, {
  Map<String, JmesPathFunction>? functions,
}) {
  final allFunctions = functions == null
      ? builtInFunctions
      : {...builtInFunctions, ...functions};
  final ast = parse(expression);
  validate(ast, allFunctions);
  return JmesPathExpression._(expression, ast, Interpreter(allFunctions));
}

/// A compiled JMESPath expression.
final class JmesPathExpression {
  JmesPathExpression._(this.expression, this._ast, this._interpreter);

  /// The source text of this expression.
  final String expression;

  final Node _ast;
  final Interpreter _interpreter;

  /// Evaluates this expression against [data] and returns the result.
  ///
  /// Throws a `JmesPathException` if the expression cannot be evaluated
  /// against [data] (for example if a function receives an argument of the
  /// wrong type).
  Object? search(Object? data) => _interpreter.visit(_ast, data);

  @override
  String toString() => 'JmesPathExpression($expression)';
}
