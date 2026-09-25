// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// The abstract syntax tree of a parsed JMESPath expression.
sealed class Node {
  const Node();
}

/// `@` — evaluates to the current node. Also used implicitly as the left or
/// right hand side of projections.
final class CurrentNode extends Node {
  const CurrentNode();
}

/// A field lookup such as `foo` or `"foo"`.
final class FieldNode extends Node {
  const FieldNode(this.name);
  final String name;
}

/// `left.right`.
final class SubexpressionNode extends Node {
  const SubexpressionNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// `left[index]` where the right hand side is an [IndexNode] or [SliceNode].
final class IndexExpressionNode extends Node {
  const IndexExpressionNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// `[index]`.
final class IndexNode extends Node {
  const IndexNode(this.index);
  final int index;
}

/// `[start:stop:step]`.
final class SliceNode extends Node {
  const SliceNode(this.start, this.stop, this.step);
  final int? start;
  final int? stop;
  final int? step;
}

/// A list projection: evaluates [left], and if it is a list, applies [right]
/// to each element, collecting the non-null results.
final class ProjectionNode extends Node {
  const ProjectionNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// An object projection (`left.*`): evaluates [left], and if it is an
/// object, applies [right] to each value, collecting the non-null results.
final class ValueProjectionNode extends Node {
  const ValueProjectionNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// A filter projection: `left[?condition]` followed by [right].
final class FilterProjectionNode extends Node {
  const FilterProjectionNode(this.left, this.right, this.condition);
  final Node left;
  final Node right;
  final Node condition;
}

/// `child[]`: flattens one level of nested lists.
final class FlattenNode extends Node {
  const FlattenNode(this.child);
  final Node child;
}

/// A JSON literal (`` `...` ``) or raw string literal (`'...'`).
final class LiteralNode extends Node {
  const LiteralNode(this.value);
  final Object? value;
}

/// `[a, b, c]` multi-select list.
final class MultiSelectListNode extends Node {
  const MultiSelectListNode(this.children);
  final List<Node> children;
}

/// `{a: x, b: y}` multi-select hash.
final class MultiSelectHashNode extends Node {
  const MultiSelectHashNode(this.entries);
  final List<(String, Node)> entries;
}

/// `left | right`.
final class PipeNode extends Node {
  const PipeNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// `left || right`.
final class OrNode extends Node {
  const OrNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// `left && right`.
final class AndNode extends Node {
  const AndNode(this.left, this.right);
  final Node left;
  final Node right;
}

/// `!child`.
final class NotNode extends Node {
  const NotNode(this.child);
  final Node child;
}

/// Comparison operators.
enum Comparator { eq, ne, lt, lte, gt, gte }

/// `left <op> right`.
final class ComparatorNode extends Node {
  const ComparatorNode(this.comparator, this.left, this.right);
  final Comparator comparator;
  final Node left;
  final Node right;
}

/// `name(args...)`.
final class FunctionCallNode extends Node {
  const FunctionCallNode(this.name, this.arguments);
  final String name;
  final List<Node> arguments;
}

/// `&expression`.
final class ExpressionReferenceNode extends Node {
  const ExpressionReferenceNode(this.expression);
  final Node expression;
}
