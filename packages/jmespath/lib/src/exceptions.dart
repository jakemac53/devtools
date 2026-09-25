// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// The category of a [JmesPathException].
///
/// The [id] of each value matches the `error` values used by the official
/// JMESPath compliance test suite.
enum JmesPathErrorType {
  /// The expression is not syntactically valid.
  syntax('syntax'),

  /// A function was called with an argument of the wrong type.
  invalidType('invalid-type'),

  /// A semantically invalid value was provided (for example a slice step of
  /// zero).
  invalidValue('invalid-value'),

  /// A function was called with the wrong number of arguments.
  invalidArity('invalid-arity'),

  /// An unknown function was called.
  unknownFunction('unknown-function');

  const JmesPathErrorType(this.id);

  /// The identifier used for this error type by the compliance test suite.
  final String id;
}

/// Base class for all errors thrown while compiling or evaluating a JMESPath
/// expression.
sealed class JmesPathException implements Exception {
  JmesPathException(this.message);

  /// A human readable description of the error.
  final String message;

  /// The category of this error.
  JmesPathErrorType get type;

  @override
  String toString() => '${type.id}: $message';
}

/// Thrown when an expression is not syntactically valid.
final class JmesPathSyntaxException extends JmesPathException {
  JmesPathSyntaxException(super.message, {this.expression, this.offset});

  /// The expression that failed to parse, if known.
  final String? expression;

  /// The offset into [expression] at which the error was detected, if known.
  final int? offset;

  @override
  JmesPathErrorType get type => JmesPathErrorType.syntax;

  @override
  String toString() {
    final expression = this.expression;
    final offset = this.offset;
    if (expression == null || offset == null) return super.toString();
    return '${super.toString()}\n$expression\n${' ' * offset}^';
  }
}

/// Thrown when a function receives an argument of an invalid type.
final class JmesPathInvalidTypeException extends JmesPathException {
  JmesPathInvalidTypeException(super.message);

  @override
  JmesPathErrorType get type => JmesPathErrorType.invalidType;
}

/// Thrown when a semantically invalid value is encountered (for example a
/// slice with a step of zero).
final class JmesPathInvalidValueException extends JmesPathException {
  JmesPathInvalidValueException(super.message);

  @override
  JmesPathErrorType get type => JmesPathErrorType.invalidValue;
}

/// Thrown when a function is called with the wrong number of arguments.
final class JmesPathInvalidArityException extends JmesPathException {
  JmesPathInvalidArityException(super.message);

  @override
  JmesPathErrorType get type => JmesPathErrorType.invalidArity;
}

/// Thrown when an expression calls a function that does not exist.
final class JmesPathUnknownFunctionException extends JmesPathException {
  JmesPathUnknownFunctionException(super.message);

  @override
  JmesPathErrorType get type => JmesPathErrorType.unknownFunction;
}
