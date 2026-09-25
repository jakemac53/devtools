// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

/// A map of key-value pairs representing a JSON object.
typedef JsonObject = Map<String, Object?>;

/// Converts [value] into a structure containing only JSON primitives, lists,
/// and string-keyed maps.
///
/// [DateTime]s are converted to milliseconds since epoch, [Duration]s to
/// microseconds, enums to their name, and any other object to its
/// `toString()`.
Object? toJsonSafe(Object? value) {
  return switch (value) {
    null || bool() || String() => value,
    num() => value.isFinite ? value : value.toString(),
    DateTime() => value.millisecondsSinceEpoch,
    Duration() => value.inMicroseconds,
    Enum() => value.name,
    Map() => {
      for (final entry in value.entries)
        entry.key.toString(): toJsonSafe(entry.value),
    },
    Iterable() => [for (final e in value) toJsonSafe(e)],
    _ => value.toString(),
  };
}

/// Truncates long lists (recursively) in [value] so that it can be shown to
/// an agent without blowing up its context window.
///
/// Truncated lists are replaced with a map describing the omitted items.
Object? truncateForPreview(
  Object? value, {
  int maxListLength = 5,
  int maxStringLength = 500,
  int maxDepth = 8,
}) {
  Object? helper(Object? v, int depth) {
    if (depth > maxDepth) return '…';
    return switch (v) {
      String() when v.length > maxStringLength =>
        '${v.substring(0, maxStringLength)}…',
      List() when v.length > maxListLength => {
        'items': [for (final e in v.take(maxListLength)) helper(e, depth + 1)],
        'totalLength': v.length,
        'truncated': true,
      },
      List() => [for (final e in v) helper(e, depth + 1)],
      Map() => {
        for (final entry in v.entries)
          entry.key.toString(): helper(entry.value, depth + 1),
      },
      _ => v,
    };
  }

  return helper(value, 0);
}
