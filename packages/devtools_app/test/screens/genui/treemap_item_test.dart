// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app/src/screens/genui/catalog/json_column_data.dart';
import 'package:devtools_app/src/screens/genui/catalog/treemap_item.dart';
import 'package:devtools_app/src/shared/charts/treemap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _sizes(TreemapNode node) => {
  for (final child in node.children)
    child.name: child.children.isEmpty ? child.byteSize : _sizes(child),
};

void main() {
  group('buildGenUiTreemap', () {
    test('groups flat rows by fields, largest first', () {
      final root = buildGenUiTreemap(
        [
          {'package': 'a', 'library': 'a/x', 'class': 'X1', 'bytes': 10},
          {'package': 'a', 'library': 'a/x', 'class': 'X2', 'bytes': 30},
          {'package': 'a', 'library': 'a/y', 'class': 'Y', 'bytes': 5},
          {'package': 'b', 'library': 'b/z', 'class': 'Z', 'bytes': 100},
          {'library': 'c', 'class': 'NoPackage', 'bytes': 1},
          {'package': 'a', 'library': 'a/x', 'class': 'Zero', 'bytes': 0},
          {'package': 'a', 'library': 'a/x', 'class': 'Bad', 'bytes': 'x'},
        ],
        rootName: 'Heap',
        groupBy: ['package', 'library'],
        labelField: 'class',
        valueField: 'bytes',
        format: JsonColumnFormat.bytes,
      );
      expect(root.name, 'Heap');
      expect(root.byteSize, 146);
      expect(root.children.map((c) => c.name), ['b', 'a', '(none)']);
      expect(_sizes(root), {
        'b': {
          'b/z': {'Z': 100},
        },
        'a': {
          'a/x': {'X2': 30, 'X1': 10},
          'a/y': {'Y': 5},
        },
        '(none)': {
          'c': {'NoPackage': 1},
        },
      });
      expect(root.children.first.byteSize, 100);
      expect(root.children[1].byteSize, 45);
    });

    test('reads hierarchical rows, adding <self> for own values', () {
      final root = buildGenUiTreemap(
        [
          {
            'name': 'app',
            'value': 10,
            'children': [
              {'name': 'a', 'value': 3},
              {'name': 'b', 'value': 4},
            ],
          },
          {
            'name': 'lib',
            'children': [
              {'name': 'c', 'value': 2},
              {'name': 'c', 'value': 1},
            ],
          },
        ],
        rootName: 'Total',
        format: JsonColumnFormat.bytes,
      );
      expect(root.byteSize, 13);
      expect(_sizes(root), {
        'app': {'b': 4, 'a': 3, '<self>': 3},
        'lib': {'c': 2, 'c (2)': 1},
      });
    });

    test('groups extra children into Other', () {
      final root = buildGenUiTreemap(
        [
          for (var i = 1; i <= 5; i++) {'name': 'n$i', 'value': i},
        ],
        rootName: 'Total',
        maxChildren: 3,
        format: JsonColumnFormat.bytes,
      );
      expect(_sizes(root), {'n5': 5, 'n4': 4, 'Other': 6});
    });

    test('scales fractional values and formats them', () {
      final root = buildGenUiTreemap(
        [
          {'name': 'a', 'value': 0.25},
          {'name': 'b', 'value': 0.75},
        ],
        rootName: 'Total',
        format: JsonColumnFormat.percent,
      );
      final b = root.children.first;
      expect(b.name, 'b');
      expect(b.byteSize, 750);
      expect(
        b.prettyByteSize(),
        formatJsonValue(0.75, JsonColumnFormat.percent),
      );
    });

    test('handles missing data', () {
      expect(buildGenUiTreemap(null, rootName: 'Total').byteSize, 0);
      expect(buildGenUiTreemap([], rootName: 'Total').children, isEmpty);
    });
  });

  testWidgets('GenUiTreemap renders and zooms in', (tester) async {
    final root = buildGenUiTreemap(
      [
        {'package': 'a', 'class': 'A1', 'bytes': 300},
        {'package': 'a', 'class': 'A2', 'bytes': 100},
        {'package': 'b', 'class': 'B1', 'bytes': 200},
      ],
      rootName: 'Heap',
      groupBy: ['package'],
      labelField: 'class',
      valueField: 'bytes',
      format: JsonColumnFormat.bytes,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: GenUiTreemap(root: root),
          ),
        ),
      ),
    );
    expect(find.byType(Treemap), findsWidgets);
    expect(tester.takeException(), isNull);

    // Tap the "a" group's title bar to zoom into it.
    await tester.tap(find.textContaining('a [', findRichText: true).first);
    await tester.pumpAndSettle();
    final outermost = tester
        .widgetList<Treemap>(find.byType(Treemap))
        .firstWhere((t) => t.isOutermostLevel);
    expect(outermost.rootNode!.name, 'a');
  });
}
