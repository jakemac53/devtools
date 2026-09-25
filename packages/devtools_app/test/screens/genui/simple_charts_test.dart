// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app/src/screens/genui/catalog/json_column_data.dart';
import 'package:devtools_app/src/screens/genui/catalog/simple_charts_item.dart';
import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: themeFor(isDarkTheme: false, ideTheme: IdeTheme(), theme: ThemeData()),
  home: Scaffold(body: SizedBox(width: 500, child: child)),
);

void main() {
  test('readJsonField traverses nested maps', () {
    expect(readJsonField({'a': 1}, 'a'), 1);
    expect(
      readJsonField({
        'a': {'b': 2},
      }, 'a.b'),
      2,
    );
    expect(readJsonField({'a': 1}, 'a.b'), isNull);
    expect(readJsonField('x', 'a'), isNull);
  });

  test('labeledValues keeps order and skips non-numeric values', () {
    final values = labeledValues(
      [
        {'name': 'a', 'v': 3},
        {'name': 'b', 'v': 'nope'},
        {'name': 'c', 'v': 1.5},
        {'v': 2},
      ],
      labelField: 'name',
      valueField: 'v',
    );
    expect(values, const [
      LabeledValue('a', 3),
      LabeledValue('c', 1.5),
      LabeledValue('', 2),
    ]);
    expect(labeledValues(null, labelField: 'a', valueField: 'b'), isEmpty);
  });

  test('pieSlices sorts, drops non-positive values, and groups Other', () {
    final values = [
      for (final (i, v) in [5, 0, 1, 9, 3, -2, 4].indexed)
        LabeledValue('s$i', v.toDouble()),
    ];
    expect(pieSlices(values), const [
      LabeledValue('s3', 9),
      LabeledValue('s0', 5),
      LabeledValue('s6', 4),
      LabeledValue('s4', 3),
      LabeledValue('s2', 1),
    ]);
    expect(pieSlices(values, maxSlices: 3), const [
      LabeledValue('s3', 9),
      LabeledValue('s0', 5),
      LabeledValue('Other', 8),
    ]);
  });

  test('numericSeries reads numbers or a field of rows', () {
    expect(numericSeries([1, 2.5, 'x']), [1.0, 2.5]);
    expect(
      numericSeries([
        {'used': 1},
        {'used': 2},
        {},
      ], field: 'used'),
      [1.0, 2.0],
    );
    expect(numericSeries(null), isEmpty);
  });

  test('StatCard.thresholdColor', () {
    const scheme = ColorScheme.light();
    Color? color(Object? v) => StatCard.thresholdColor(
      v,
      warnAbove: 0.5,
      errorAbove: 0.8,
      colorScheme: scheme,
    );
    expect(color(0.2), isNull);
    expect(color(0.6), Colors.orange);
    expect(color(0.9), scheme.error);
    expect(color('0.9'), isNull);
  });

  testWidgets('SimpleBarChart shows labels and formatted values', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const SimpleBarChart(
          title: 'Top',
          values: [LabeledValue('Foo', 2048), LabeledValue('Bar', 1024)],
          format: JsonColumnFormat.bytes,
        ),
      ),
    );
    expect(find.text('Top'), findsOneWidget);
    expect(find.text('Foo'), findsOneWidget);
    expect(find.text('Bar'), findsOneWidget);
    expect(find.text(formatJsonValue(2048, JsonColumnFormat.bytes)), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SimplePieChart shows a legend with percentages', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SimplePieChart(
          slices: [LabeledValue('app', 3), LabeledValue('flutter', 1)],
        ),
      ),
    );
    expect(find.text('app'), findsOneWidget);
    expect(find.textContaining('75'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty charts show "No data"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const Column(
          children: [
            SimpleBarChart(values: []),
            SimplePieChart(slices: []),
          ],
        ),
      ),
    );
    expect(find.text('No data'), findsNWidgets(2));
  });

  testWidgets('StatCard shows the value, caption, and a sparkline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const StatCard(
          label: 'CPU',
          value: 0.42,
          format: JsonColumnFormat.percent,
          caption: 'last 5s',
          history: [0.1, 0.4, 0.42],
        ),
      ),
    );
    expect(find.text('CPU'), findsOneWidget);
    expect(
      find.text(formatJsonValue(0.42, JsonColumnFormat.percent)),
      findsOneWidget,
    );
    expect(find.text('last 5s'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StatCard),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });
}
