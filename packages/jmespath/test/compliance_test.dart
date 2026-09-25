// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:jmespath/jmespath.dart';
import 'package:test/test.dart';

/// Runs the official JMESPath compliance test suite, vendored from
/// https://github.com/jmespath/jmespath.test into `test/compliance/`.
///
/// Must be run from the package root (as `dart test` does).
void main() {
  final fixtures = Directory('test/compliance')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('compliance fixtures are present', () {
    expect(fixtures, hasLength(16));
  });

  for (final file in fixtures) {
    final name = file.uri.pathSegments.last.replaceAll('.json', '');
    final suites = jsonDecode(file.readAsStringSync()) as List<Object?>;
    group(name, () {
      for (var s = 0; s < suites.length; s++) {
        final suite = suites[s] as Map<String, Object?>;
        final given = suite['given'];
        final cases = suite['cases'] as List<Object?>;
        for (var c = 0; c < cases.length; c++) {
          final testCase = cases[c] as Map<String, Object?>;
          final expression = testCase['expression'] as String;
          test('suite $s case $c: $expression', () {
            if (testCase.containsKey('error')) {
              final errorType = testCase['error'] as String;
              expect(
                () => search(expression, given),
                throwsA(
                  isA<JmesPathException>().having(
                    (e) => e.type.id,
                    'type.id',
                    errorType,
                  ),
                ),
              );
            } else if (testCase.containsKey('bench')) {
              final bench = testCase['bench'] as String;
              if (bench == 'parse') {
                compile(expression);
              } else {
                search(expression, given);
              }
            } else {
              final expected = testCase['result'];
              final actual = search(expression, given);
              expect(
                jsonEquals(actual, expected),
                isTrue,
                reason: 'Expected ${jsonEncode(expected)}\n'
                    'Actual:  ${jsonEncode(actual)}',
              );
            }
          });
        }
      }
    });
  }
}
