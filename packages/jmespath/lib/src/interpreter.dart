// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'ast.dart';
import 'exceptions.dart';
import 'functions.dart';
import 'values.dart';

/// Statically validates [node], throwing for errors that do not depend on the
/// input data: unknown functions, wrong function arity and zero slice steps.
void validate(Node node, Map<String, JmesPathFunction> functions) {
  void visit(Node node) {
    switch (node) {
      case CurrentNode() || FieldNode() || IndexNode() || LiteralNode():
        break;
      case SliceNode(:final step):
        if (step == 0) {
          throw JmesPathInvalidValueException('Slice step cannot be 0');
        }
      case SubexpressionNode(:final left, :final right) ||
            IndexExpressionNode(:final left, :final right) ||
            ProjectionNode(:final left, :final right) ||
            ValueProjectionNode(:final left, :final right) ||
            PipeNode(:final left, :final right) ||
            OrNode(:final left, :final right) ||
            AndNode(:final left, :final right) ||
            ComparatorNode(:final left, :final right):
        visit(left);
        visit(right);
      case FilterProjectionNode(:final left, :final right, :final condition):
        visit(left);
        visit(condition);
        visit(right);
      case FlattenNode(child: final inner) ||
            NotNode(child: final inner) ||
            ExpressionReferenceNode(expression: final inner):
        visit(inner);
      case MultiSelectListNode(:final children):
        children.forEach(visit);
      case MultiSelectHashNode(:final entries):
        for (final (_, value) in entries) {
          visit(value);
        }
      case FunctionCallNode(:final name, :final arguments):
        final function = functions[name];
        if (function == null) {
          throw JmesPathUnknownFunctionException('Unknown function: $name()');
        }
        function.checkArity(name, arguments.length);
        arguments.forEach(visit);
    }
  }

  visit(node);
}

/// Evaluates JMESPath ASTs against JSON-like data.
final class Interpreter {
  Interpreter(this.functions);

  final Map<String, JmesPathFunction> functions;

  Object? visit(Node node, Object? value) {
    switch (node) {
      case CurrentNode():
        return value;
      case FieldNode(:final name):
        return value is Map ? value[name] : null;
      case SubexpressionNode(:final left, :final right):
        return visit(right, visit(left, value));
      case IndexExpressionNode(:final left, :final right):
        return visit(right, visit(left, value));
      case IndexNode(:final index):
        if (value is! List) return null;
        final i = index < 0 ? value.length + index : index;
        return i >= 0 && i < value.length ? value[i] : null;
      case SliceNode():
        return value is List ? _slice(value, node) : null;
      case ProjectionNode(:final left, :final right):
        final base = visit(left, value);
        if (base is! List) return null;
        return _project(base, right);
      case ValueProjectionNode(:final left, :final right):
        final base = visit(left, value);
        if (base is! Map) return null;
        return _project(base.values, right);
      case FilterProjectionNode(:final left, :final right, :final condition):
        final base = visit(left, value);
        if (base is! List) return null;
        return _project(
          base.where((e) => isTruthy(visit(condition, e))),
          right,
        );
      case FlattenNode(:final child):
        final base = visit(child, value);
        if (base is! List) return null;
        return [
          for (final element in base)
            if (element is List) ...element else element,
        ];
      case LiteralNode(value: final literal):
        return literal;
      case MultiSelectListNode(:final children):
        if (value == null) return null;
        return [for (final child in children) visit(child, value)];
      case MultiSelectHashNode(:final entries):
        if (value == null) return null;
        return <String, Object?>{
          for (final (key, child) in entries) key: visit(child, value),
        };
      case PipeNode(:final left, :final right):
        return visit(right, visit(left, value));
      case OrNode(:final left, :final right):
        final result = visit(left, value);
        return isTruthy(result) ? result : visit(right, value);
      case AndNode(:final left, :final right):
        final result = visit(left, value);
        return isTruthy(result) ? visit(right, value) : result;
      case NotNode(:final child):
        return !isTruthy(visit(child, value));
      case ComparatorNode(:final comparator, :final left, :final right):
        return _compare(comparator, visit(left, value), visit(right, value));
      case FunctionCallNode(:final name, :final arguments):
        final function = functions[name];
        if (function == null) {
          throw JmesPathUnknownFunctionException('Unknown function: $name()');
        }
        return function.call(name, [
          for (final argument in arguments) visit(argument, value),
        ]);
      case ExpressionReferenceNode(:final expression):
        return _ExpressionReference(this, expression);
    }
  }

  List<Object?> _project(Iterable<Object?> elements, Node right) => [
        for (final element in elements)
          if (visit(right, element) case final result?) result,
      ];

  Object? _compare(Comparator comparator, Object? left, Object? right) {
    switch (comparator) {
      case Comparator.eq:
        return jsonEquals(left, right);
      case Comparator.ne:
        return !jsonEquals(left, right);
      case Comparator.lt || Comparator.lte || Comparator.gt || Comparator.gte:
        if (left is! num || right is! num) return null;
        return switch (comparator) {
          Comparator.lt => left < right,
          Comparator.lte => left <= right,
          Comparator.gt => left > right,
          _ => left >= right,
        };
    }
  }

  List<Object?> _slice(List<Object?> list, SliceNode slice) {
    final step = slice.step ?? 1;
    if (step == 0) {
      throw JmesPathInvalidValueException('Slice step cannot be 0');
    }
    final length = list.length;
    int cap(int index) {
      if (index < 0) {
        index += length;
        if (index < 0) index = step < 0 ? -1 : 0;
      } else if (index >= length) {
        index = step < 0 ? length - 1 : length;
      }
      return index;
    }

    final start =
        slice.start == null ? (step < 0 ? length - 1 : 0) : cap(slice.start!);
    final stop =
        slice.stop == null ? (step < 0 ? -1 : length) : cap(slice.stop!);
    return [
      if (step > 0)
        for (var i = start; i < stop; i += step) list[i]
      else
        for (var i = start; i > stop; i += step) list[i],
    ];
  }
}

final class _ExpressionReference implements ExpressionReference {
  _ExpressionReference(this._interpreter, this._node);

  final Interpreter _interpreter;
  final Node _node;

  @override
  Object? evaluate(Object? data) => _interpreter.visit(_node, data);
}
