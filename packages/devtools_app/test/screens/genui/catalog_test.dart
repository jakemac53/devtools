// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:devtools_app/src/screens/genui/catalog/json_column_data.dart';
import 'package:devtools_app/src/screens/genui/catalog/json_table_item.dart';
import 'package:devtools_app/src/screens/genui/catalog/key_value_item.dart';
import 'package:devtools_app/src/screens/genui/catalog/time_series_chart_item.dart';
import 'package:devtools_app/src/screens/genui/genui_spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsonColumnData', () {
    test('formats values with the DevTools formatters', () {
      expect(formatJsonValue(null, JsonColumnFormat.bytes), '');
      expect(formatJsonValue(2048, JsonColumnFormat.bytes), '2.0 KB');
      expect(formatJsonValue(12.5, JsonColumnFormat.duration), '12.5 ms');
      expect(formatJsonValue(0.25, JsonColumnFormat.percent), '25.00%');
      expect(formatJsonValue(3.0, JsonColumnFormat.number), '3');
      expect(formatJsonValue(3.14159, JsonColumnFormat.number), '3.14');
      expect(formatJsonValue(true, JsonColumnFormat.boolean), '✓');
      expect(formatJsonValue(false, JsonColumnFormat.boolean), '');
      expect(formatJsonValue({'a': 1}, JsonColumnFormat.string), '{"a":1}');
      expect(
        formatJsonValue(0, JsonColumnFormat.timestamp),
        matches(RegExp(r'^\d\d:\d\d:\d\d$')),
      );
      expect(formatJsonValue('x', JsonColumnFormat.bytes), 'x');
    });

    test('parses formats leniently', () {
      expect(JsonColumnFormat.parse('bytes'), JsonColumnFormat.bytes);
      expect(JsonColumnFormat.parse('nope'), JsonColumnFormat.string);
      expect(JsonColumnFormat.parse(null), JsonColumnFormat.string);
    });

    test('fromJson reads nested fields', () {
      final column = JsonColumnData.fromJson({
        'field': 'request.size',
        'title': 'Size',
        'format': 'bytes',
      });
      expect(column.title, 'Size');
      expect(column.numeric, isTrue);
      final row = {
        'request': {'size': 1024},
      };
      expect(column.getValue(row), 1024);
      expect(column.getDisplayValue(row), '1.0 KB');
      expect(column.getValue({'request': 1}), isNull);
    });

    test('fromJson supports wide columns and requires a field', () {
      final wide = JsonColumnData.fromJson({'field': 'uri', 'wide': true});
      expect(wide.title, 'uri');
      expect(wide.fixedWidthPx, isNull);
      expect(() => JsonColumnData.fromJson({}), throwsFormatException);
    });

    test('compares booleans', () {
      final column = JsonColumnData(
        title: 'b',
        field: 'b',
        format: JsonColumnFormat.boolean,
      );
      expect(column.compare({'b': true}, {'b': false}), greaterThan(0));
    });

    test('parseColumns uses explicit columns, then presets', () {
      expect(
        parseColumns({
          'columns': [
            {'field': 'a'},
          ],
          'preset': 'network.requests',
        }).map((c) => c.field),
        ['a'],
      );
      expect(
        parseColumns({'preset': 'network.requests'}).map((c) => c.field),
        contains('uri'),
      );
      expect(parseColumns({}), isEmpty);
    });
  });

  group('KeyValue', () {
    test('rows default to all fields except _ref', () {
      final rows = keyValueRows({'a': 1, '_ref': 'x', 'b': 'two'}, const []);
      expect(rows.map((r) => r.key), ['a', 'b']);
    });

    test('rows honor labels and ordering', () {
      final rows = keyValueRows(
        {'a': 1, 'b': 2048},
        const [
          {'field': 'b', 'label': 'Bytes', 'format': 'bytes'},
        ],
      );
      expect(rows.map((r) => r.key), ['Bytes']);
    });
  });

  group('TimeSeriesChart', () {
    test('parseHexColor', () {
      expect(parseHexColor('#ff0000'), const Color(0xffff0000));
      expect(parseHexColor('80ff0000'), const Color(0x80ff0000));
      expect(parseHexColor('red'), isNull);
      expect(parseHexColor(null), isNull);
    });

    test('JsonChartController appends only new rows', () {
      final controller = JsonChartController(const [
        ChartSeries(field: 'used'),
        ChartSeries(field: 'capacity'),
      ], 'timestamp');
      addTearDown(controller.dispose);

      controller.sync([
        {'timestamp': 1, 'used': 10, 'capacity': 20},
        {'timestamp': 2, 'used': 11, 'capacity': 20},
      ]);
      expect(controller.timestamps, [1, 2]);
      expect(controller.trace(0).data.map((d) => d.y), [10, 11]);

      // A sliding window that overlaps with already plotted data.
      controller.sync([
        {'timestamp': 2, 'used': 11, 'capacity': 20},
        {'timestamp': 3, 'used': 12},
      ]);
      expect(controller.timestamps, [1, 2, 3]);
      expect(controller.trace(1).data.map((d) => d.y), [20, 20, 0]);

      // Data went backwards (e.g. the source was cleared): reset.
      controller.sync([
        {'timestamp': 0, 'used': 1, 'capacity': 1},
      ]);
      expect(controller.timestamps, [0]);
    });
  });

  group('spec', () {
    test('round trips via parseSpec', () {
      final spec = jsonEncode({
        'messages': [
          core.CreateSurfaceMessage(
            surfaceId: 'main',
            catalogId: 'cat',
          ).toJson(),
          core.UpdateComponentsMessage(
            surfaceId: 'main',
            components: [
              {'id': 'root', 'component': 'Text', 'text': 'hi'},
            ],
          ).toJson(),
        ],
      });
      final messages = parseSpec(spec);
      expect(messages, hasLength(2));
      expect(messages.first, isA<core.CreateSurfaceMessage>());
      final update = messages.last as core.UpdateComponentsMessage;
      expect(update.components.single['text'], 'hi');
    });

    test('accepts a bare list and rejects invalid input', () {
      expect(parseSpec('[]'), isEmpty);
      expect(() => parseSpec('{}'), throwsFormatException);
      expect(() => parseSpec('[1]'), throwsFormatException);
    });
  });
}
