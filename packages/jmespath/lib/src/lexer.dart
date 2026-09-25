// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'exceptions.dart';

/// The kinds of tokens produced by [tokenize].
enum TokenType {
  unquotedIdentifier,
  quotedIdentifier,
  rawString,
  literal,
  number,
  dot,
  star,
  flatten,
  filter,
  lbracket,
  rbracket,
  lbrace,
  rbrace,
  lparen,
  rparen,
  comma,
  colon,
  pipe,
  or,
  and,
  not,
  expref,
  current,
  eq,
  ne,
  lt,
  lte,
  gt,
  gte,
  eof,
}

/// A single lexical token of a JMESPath expression.
final class Token {
  const Token(this.type, this.start, [this.value]);

  final TokenType type;

  /// The offset of the first character of this token in the expression.
  final int start;

  /// The value of the token, for identifiers, literals and numbers.
  final Object? value;

  @override
  String toString() => value == null ? type.name : '${type.name}($value)';
}

const _simpleTokens = <String, TokenType>{
  '.': TokenType.dot,
  '*': TokenType.star,
  ']': TokenType.rbracket,
  ',': TokenType.comma,
  ':': TokenType.colon,
  '@': TokenType.current,
  '(': TokenType.lparen,
  ')': TokenType.rparen,
  '{': TokenType.lbrace,
  '}': TokenType.rbrace,
};

bool _isIdentifierStart(int c) =>
    (c >= 0x61 && c <= 0x7a) || // a-z
    (c >= 0x41 && c <= 0x5a) || // A-Z
    c == 0x5f; // _

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentifierPart(int c) => _isIdentifierStart(c) || _isDigit(c);

/// Splits [expression] into a list of tokens, always ending in a
/// [TokenType.eof] token.
List<Token> tokenize(String expression) => _Lexer(expression).tokenize();

class _Lexer {
  _Lexer(this.expression);

  final String expression;
  int _pos = 0;

  Never _error(String message, int offset) => throw JmesPathSyntaxException(
        message,
        expression: expression,
        offset: offset,
      );

  List<Token> tokenize() {
    final tokens = <Token>[];
    final length = expression.length;
    while (_pos < length) {
      final start = _pos;
      final char = expression[_pos];
      final code = expression.codeUnitAt(_pos);
      final simple = _simpleTokens[char];
      if (simple != null) {
        tokens.add(Token(simple, start));
        _pos++;
      } else if (_isIdentifierStart(code)) {
        _pos++;
        while (
            _pos < length && _isIdentifierPart(expression.codeUnitAt(_pos))) {
          _pos++;
        }
        tokens.add(
          Token(
            TokenType.unquotedIdentifier,
            start,
            expression.substring(start, _pos),
          ),
        );
      } else if (char == ' ' || char == '\t' || char == '\n' || char == '\r') {
        _pos++;
      } else if (char == '[') {
        _pos++;
        final next = _peek();
        if (next == ']') {
          _pos++;
          tokens.add(Token(TokenType.flatten, start));
        } else if (next == '?') {
          _pos++;
          tokens.add(Token(TokenType.filter, start));
        } else {
          tokens.add(Token(TokenType.lbracket, start));
        }
      } else if (char == "'") {
        final raw = _consumeUntil("'").replaceAll(r"\'", "'");
        tokens.add(Token(TokenType.rawString, start, raw));
      } else if (char == '"') {
        final raw = _consumeUntil('"');
        try {
          tokens.add(
            Token(TokenType.quotedIdentifier, start, jsonDecode('"$raw"')),
          );
        } on FormatException catch (e) {
          _error('Invalid quoted identifier: ${e.message}', start);
        }
      } else if (char == '`') {
        final raw = _consumeUntil('`').replaceAll(r'\`', '`');
        tokens.add(Token(TokenType.literal, start, _parseLiteral(raw, start)));
      } else if (char == '-' || _isDigit(code)) {
        _pos++;
        while (_pos < length && _isDigit(expression.codeUnitAt(_pos))) {
          _pos++;
        }
        final text = expression.substring(start, _pos);
        if (text == '-') _error("Unknown token '-'", start);
        tokens.add(Token(TokenType.number, start, int.parse(text)));
      } else if (char == '|') {
        tokens.add(_matchOr('|', TokenType.or, TokenType.pipe));
      } else if (char == '&') {
        tokens.add(_matchOr('&', TokenType.and, TokenType.expref));
      } else if (char == '<') {
        tokens.add(_matchOr('=', TokenType.lte, TokenType.lt));
      } else if (char == '>') {
        tokens.add(_matchOr('=', TokenType.gte, TokenType.gt));
      } else if (char == '!') {
        tokens.add(_matchOr('=', TokenType.ne, TokenType.not));
      } else if (char == '=') {
        _pos++;
        if (_peek() != '=') _error("Unknown token '=', expected '=='", start);
        _pos++;
        tokens.add(Token(TokenType.eq, start));
      } else {
        _error("Unknown token '$char'", start);
      }
    }
    tokens.add(Token(TokenType.eof, _pos));
    return tokens;
  }

  String? _peek() => _pos < expression.length ? expression[_pos] : null;

  /// Consumes the current character, then produces [ifMatch] if the following
  /// character is [next] (consuming it too), otherwise [otherwise].
  Token _matchOr(String next, TokenType ifMatch, TokenType otherwise) {
    final start = _pos;
    _pos++;
    if (_peek() == next) {
      _pos++;
      return Token(ifMatch, start);
    }
    return Token(otherwise, start);
  }

  /// Consumes a delimited sequence starting at the current position (which
  /// must be the opening [delimiter]) and returns the raw contents between the
  /// delimiters. Backslash escapes are preserved verbatim in the result, but
  /// an escaped delimiter does not terminate the sequence.
  String _consumeUntil(String delimiter) {
    final start = _pos;
    _pos++;
    final buffer = StringBuffer();
    while (true) {
      if (_pos >= expression.length) {
        _error('Unclosed $delimiter delimiter', start);
      }
      final char = expression[_pos];
      if (char == delimiter) break;
      if (char == r'\') {
        buffer.write(char);
        _pos++;
        if (_pos >= expression.length) {
          _error('Unclosed $delimiter delimiter', start);
        }
      }
      buffer.write(expression[_pos]);
      _pos++;
    }
    _pos++;
    return buffer.toString();
  }

  Object? _parseLiteral(String raw, int start) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      // Fall back to the deprecated behavior of treating the literal contents
      // as the body of a JSON string, as the reference implementation does.
      try {
        return jsonDecode('"${raw.trimLeft()}"');
      } on FormatException {
        _error('Invalid JSON literal: $raw', start);
      }
    }
  }
}
