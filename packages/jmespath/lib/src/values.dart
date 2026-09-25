// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// Returns whether [value] is "truthy" according to the JMESPath
/// specification.
///
/// The false-like values are `false`, `null`, empty strings, empty lists and
/// empty objects. Everything else (including the number `0`) is truthy.
bool isTruthy(Object? value) => switch (value) {
      null => false,
      bool() => value,
      String() => value.isNotEmpty,
      List() => value.isNotEmpty,
      Map() => value.isNotEmpty,
      _ => true,
    };

/// Deep equality of two JSON-like values, following JMESPath semantics.
///
/// Numbers are compared by numeric value (so `1` equals `1.0`), lists are
/// compared element-wise and maps are compared by key/value pairs regardless
/// of ordering.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!jsonEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  return false;
}

/// Compares two strings by Unicode code point, rather than by UTF-16 code
/// unit as [String.compareTo] does.
int compareCodePoints(String a, String b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = a.codeUnitAt(i);
    final y = b.codeUnitAt(i);
    if (x != y) return _codePointOrder(x) - _codePointOrder(y);
  }
  return a.length - b.length;
}

/// Maps a UTF-16 code unit to a value whose ordering matches code point
/// ordering: surrogates (which encode code points above U+FFFF) sort after
/// all other BMP code units.
int _codePointOrder(int unit) {
  if (unit >= 0xE000) return unit - 0x800;
  if (unit >= 0xD800) return unit + 0x2000;
  return unit;
}
