// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'ast.dart';
import 'exceptions.dart';
import 'lexer.dart';

/// Parses [expression] into an AST, throwing a [JmesPathSyntaxException] if
/// it is not valid.
Node parse(String expression) => _Parser(expression).parse();

/// Binding powers used by the Pratt parser, matching the reference
/// implementation.
const _bindingPower = <TokenType, int>{
  TokenType.eof: 0,
  TokenType.unquotedIdentifier: 0,
  TokenType.quotedIdentifier: 0,
  TokenType.rawString: 0,
  TokenType.literal: 0,
  TokenType.rbracket: 0,
  TokenType.rparen: 0,
  TokenType.comma: 0,
  TokenType.rbrace: 0,
  TokenType.number: 0,
  TokenType.current: 0,
  TokenType.expref: 0,
  TokenType.colon: 0,
  TokenType.pipe: 1,
  TokenType.or: 2,
  TokenType.and: 3,
  TokenType.eq: 5,
  TokenType.ne: 5,
  TokenType.lt: 5,
  TokenType.lte: 5,
  TokenType.gt: 5,
  TokenType.gte: 5,
  TokenType.flatten: 9,
  TokenType.star: 20,
  TokenType.filter: 21,
  TokenType.dot: 40,
  TokenType.not: 45,
  TokenType.lbrace: 50,
  TokenType.lbracket: 55,
  TokenType.lparen: 60,
};

/// Tokens with a binding power below this value terminate a projection.
const _projectionStop = 10;

const _comparators = <TokenType, Comparator>{
  TokenType.eq: Comparator.eq,
  TokenType.ne: Comparator.ne,
  TokenType.lt: Comparator.lt,
  TokenType.lte: Comparator.lte,
  TokenType.gt: Comparator.gt,
  TokenType.gte: Comparator.gte,
};

class _Parser {
  _Parser(this.expression) : _tokens = tokenize(expression);

  final String expression;
  final List<Token> _tokens;
  int _index = 0;

  Token get _current => _tokens[_index];

  TokenType _lookahead(int n) {
    final i = _index + n;
    return i < _tokens.length ? _tokens[i].type : TokenType.eof;
  }

  void _advance() {
    if (_index < _tokens.length - 1) _index++;
  }

  Never _error(String message, [Token? token]) {
    token ??= _current;
    throw JmesPathSyntaxException(
      message,
      expression: expression,
      offset: token.start,
    );
  }

  Never _unexpected([Token? token]) {
    token ??= _current;
    if (token.type == TokenType.eof) _error('Unexpected end of expression');
    _error('Unexpected token: $token', token);
  }

  void _match(TokenType type) {
    if (_current.type != type) {
      if (_current.type == TokenType.eof) {
        _error('Unexpected end of expression, expected ${type.name}');
      }
      _error('Expected ${type.name}, found $_current');
    }
    _advance();
  }

  Node parse() {
    final result = _expression(0);
    if (_current.type != TokenType.eof) _unexpected();
    return result;
  }

  Node _expression(int bindingPower) {
    final token = _current;
    _advance();
    var left = _nud(token);
    while (bindingPower < _bindingPower[_current.type]!) {
      final operator = _current;
      _advance();
      left = _led(operator, left);
    }
    return left;
  }

  Node _nud(Token token) {
    switch (token.type) {
      case TokenType.literal:
      case TokenType.rawString:
        return LiteralNode(token.value);
      case TokenType.unquotedIdentifier:
        return FieldNode(token.value as String);
      case TokenType.quotedIdentifier:
        if (_current.type == TokenType.lparen) {
          _error('Quoted identifiers are not allowed as function names', token);
        }
        return FieldNode(token.value as String);
      case TokenType.star:
        final right = _current.type == TokenType.rbracket
            ? const CurrentNode()
            : _parseProjectionRhs(_bindingPower[TokenType.star]!);
        return ValueProjectionNode(const CurrentNode(), right);
      case TokenType.filter:
        return _parseFilter(const CurrentNode());
      case TokenType.lbrace:
        return _parseMultiSelectHash();
      case TokenType.lparen:
        final inner = _expression(0);
        _match(TokenType.rparen);
        return inner;
      case TokenType.flatten:
        const left = FlattenNode(CurrentNode());
        final right = _parseProjectionRhs(_bindingPower[TokenType.flatten]!);
        return ProjectionNode(left, right);
      case TokenType.not:
        return NotNode(_expression(_bindingPower[TokenType.not]!));
      case TokenType.lbracket:
        final type = _current.type;
        if (type == TokenType.number || type == TokenType.colon) {
          return _projectIfSlice(const CurrentNode(), _parseIndexExpression());
        }
        if (type == TokenType.star && _lookahead(1) == TokenType.rbracket) {
          _advance();
          _advance();
          final right = _parseProjectionRhs(_bindingPower[TokenType.star]!);
          return ProjectionNode(const CurrentNode(), right);
        }
        return _parseMultiSelectList();
      case TokenType.current:
        return const CurrentNode();
      case TokenType.expref:
        return ExpressionReferenceNode(
          _expression(_bindingPower[TokenType.expref]!),
        );
      default:
        _unexpected(token);
    }
  }

  Node _led(Token token, Node left) {
    switch (token.type) {
      case TokenType.dot:
        if (_current.type != TokenType.star) {
          final right = _parseDotRhs(_bindingPower[TokenType.dot]!);
          return SubexpressionNode(left, right);
        }
        _advance();
        final right = _parseProjectionRhs(_bindingPower[TokenType.dot]!);
        return ValueProjectionNode(left, right);
      case TokenType.pipe:
        return PipeNode(left, _expression(_bindingPower[TokenType.pipe]!));
      case TokenType.or:
        return OrNode(left, _expression(_bindingPower[TokenType.or]!));
      case TokenType.and:
        return AndNode(left, _expression(_bindingPower[TokenType.and]!));
      case TokenType.lparen:
        if (left is! FieldNode) _error('Invalid function name', token);
        final arguments = <Node>[];
        if (_current.type != TokenType.rparen) {
          while (true) {
            arguments.add(_expression(0));
            if (_current.type == TokenType.rparen) break;
            _match(TokenType.comma);
          }
        }
        _match(TokenType.rparen);
        return FunctionCallNode(left.name, arguments);
      case TokenType.filter:
        return _parseFilter(left);
      case TokenType.flatten:
        final right = _parseProjectionRhs(_bindingPower[TokenType.flatten]!);
        return ProjectionNode(FlattenNode(left), right);
      case TokenType.lbracket:
        final type = _current.type;
        if (type == TokenType.number || type == TokenType.colon) {
          return _projectIfSlice(left, _parseIndexExpression());
        }
        _match(TokenType.star);
        _match(TokenType.rbracket);
        final right = _parseProjectionRhs(_bindingPower[TokenType.star]!);
        return ProjectionNode(left, right);
      case TokenType.eq:
      case TokenType.ne:
      case TokenType.lt:
      case TokenType.lte:
      case TokenType.gt:
      case TokenType.gte:
        final right = _expression(_bindingPower[token.type]!);
        return ComparatorNode(_comparators[token.type]!, left, right);
      default:
        _unexpected(token);
    }
  }

  /// Parses the remainder of a filter expression after the `[?` token.
  Node _parseFilter(Node left) {
    final condition = _expression(0);
    _match(TokenType.rbracket);
    final right = _current.type == TokenType.flatten
        ? const CurrentNode()
        : _parseProjectionRhs(_bindingPower[TokenType.filter]!);
    return FilterProjectionNode(left, right, condition);
  }

  Node _projectIfSlice(Node left, Node right) {
    final indexExpression = IndexExpressionNode(left, right);
    if (right is SliceNode) {
      return ProjectionNode(
        indexExpression,
        _parseProjectionRhs(_bindingPower[TokenType.star]!),
      );
    }
    return indexExpression;
  }

  /// Parses an index or slice after the opening `[`, including the closing
  /// `]`.
  Node _parseIndexExpression() {
    if (_lookahead(0) == TokenType.colon || _lookahead(1) == TokenType.colon) {
      return _parseSliceExpression();
    }
    final index = _current.value as int;
    _advance();
    _match(TokenType.rbracket);
    return IndexNode(index);
  }

  Node _parseSliceExpression() {
    final parts = <int?>[null, null, null];
    var index = 0;
    while (_current.type != TokenType.rbracket && index < 3) {
      final token = _current;
      if (token.type == TokenType.colon) {
        index++;
        if (index == 3) _unexpected(token);
        _advance();
      } else if (token.type == TokenType.number) {
        parts[index] = token.value as int;
        _advance();
      } else {
        _unexpected(token);
      }
    }
    _match(TokenType.rbracket);
    return SliceNode(parts[0], parts[1], parts[2]);
  }

  /// Parses a multi-select list after the opening `[`, including the closing
  /// `]`.
  Node _parseMultiSelectList() {
    final children = <Node>[];
    while (true) {
      children.add(_expression(0));
      if (_current.type == TokenType.rbracket) break;
      _match(TokenType.comma);
    }
    _match(TokenType.rbracket);
    return MultiSelectListNode(children);
  }

  /// Parses a multi-select hash after the opening `{`, including the closing
  /// `}`.
  Node _parseMultiSelectHash() {
    final entries = <(String, Node)>[];
    while (true) {
      final keyToken = _current;
      if (keyToken.type != TokenType.unquotedIdentifier &&
          keyToken.type != TokenType.quotedIdentifier) {
        _error('Expected an identifier as a multi-select hash key', keyToken);
      }
      _advance();
      _match(TokenType.colon);
      entries.add((keyToken.value as String, _expression(0)));
      if (_current.type == TokenType.rbrace) break;
      _match(TokenType.comma);
    }
    _match(TokenType.rbrace);
    return MultiSelectHashNode(entries);
  }

  Node _parseProjectionRhs(int bindingPower) {
    final type = _current.type;
    if (_bindingPower[type]! < _projectionStop) return const CurrentNode();
    if (type == TokenType.lbracket || type == TokenType.filter) {
      return _expression(bindingPower);
    }
    if (type == TokenType.dot) {
      _advance();
      return _parseDotRhs(bindingPower);
    }
    _unexpected();
  }

  Node _parseDotRhs(int bindingPower) {
    final type = _current.type;
    if (type == TokenType.unquotedIdentifier ||
        type == TokenType.quotedIdentifier ||
        type == TokenType.star) {
      return _expression(bindingPower);
    }
    if (type == TokenType.lbracket) {
      _advance();
      return _parseMultiSelectList();
    }
    if (type == TokenType.lbrace) {
      _advance();
      return _parseMultiSelectHash();
    }
    _unexpected();
  }
}
