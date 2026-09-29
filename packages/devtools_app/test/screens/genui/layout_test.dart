// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:devtools_app/src/screens/genui/catalog/action_delegate.dart';
import 'package:devtools_app/src/screens/genui/catalog/devtools_catalog.dart';
import 'package:devtools_app/src/screens/genui/genui_screen.dart';
import 'package:devtools_app/src/screens/genui/genui_spec.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app_shared/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:material_ui/material_ui.dart';

/// Layouts that an agent is likely to generate must never throw, regardless
/// of whether it remembered to set sizes or weights.
void main() {
  const rows = [
    {'id': 'a', 'name': 'Foo', 'bytes': 100, 'timestamp': 1000},
    {'id': 'b', 'name': 'Bar', 'bytes': 200, 'timestamp': 2000},
  ];

  Map<String, Object?> table(String id, {int? weight}) => {
    'id': id,
    'component': 'JsonTable',
    'rows': rows,
    'columns': [
      {'field': 'name'},
      {'field': 'bytes', 'format': 'bytes'},
    ],
    'weight': ?weight,
  };

  Map<String, Object?> chart(String id, {int? weight}) => {
    'id': id,
    'component': 'TimeSeriesChart',
    'data': rows,
    'series': [
      {'field': 'bytes'},
    ],
    'weight': ?weight,
  };

  Map<String, Object?> keyValue(String id, {int? weight}) => {
    'id': id,
    'component': 'KeyValue',
    'title': 'Summary',
    'value': {'count': 2, 'total': 300},
    'weight': ?weight,
  };

  Map<String, Object?> text(String id, {int? weight}) => {
    'id': id,
    'component': 'Text',
    'text': 'Hello',
    'weight': ?weight,
  };

  Map<String, Object?> bar(String id) => {
    'id': id,
    'component': 'BarChart',
    'data': rows,
    'valueField': 'bytes',
    'format': 'bytes',
  };

  Map<String, Object?> pie(String id) => {
    'id': id,
    'component': 'PieChart',
    'data': rows,
    'valueField': 'bytes',
  };

  Map<String, Object?> stat(String id) => {
    'id': id,
    'component': 'Stat',
    'label': 'Total',
    'value': 300,
    'format': 'bytes',
    'history': [1, 3, 2, 5],
  };

  final layouts = <String, List<Map<String, Object?>>>{
    'Row of simple charts': [
      {
        'id': 'root',
        'component': 'Row',
        'children': ['b', 'p', 's'],
      },
      bar('b'),
      pie('p'),
      stat('s'),
    ],
    'Column of simple charts': [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['b', 'p', 's'],
      },
      bar('b'),
      pie('p'),
      stat('s'),
    ],
    'horizontal List of stats and charts': [
      {
        'id': 'root',
        'component': 'List',
        'direction': 'horizontal',
        'children': ['s1', 's2', 'b', 'p'],
      },
      stat('s1'),
      stat('s2'),
      bar('b'),
      pie('p'),
    ],
    'Row of data components without weights': [
      {
        'id': 'root',
        'component': 'Row',
        'children': ['t', 'c', 'k'],
      },
      table('t'),
      chart('c'),
      keyValue('k'),
    ],
    'Row of data components with weights': [
      {
        'id': 'root',
        'component': 'Row',
        'children': ['t', 'k'],
      },
      table('t', weight: 2),
      keyValue('k', weight: 1),
    ],
    'weighted children in the root Column': [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['title', 't', 'c'],
      },
      text('title'),
      table('t', weight: 1),
      chart('c', weight: 1),
    ],
    'weighted Row inside the root Column': [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['title', 'row'],
      },
      text('title'),
      {
        'id': 'row',
        'component': 'Row',
        'children': ['t', 'k'],
        'weight': 1,
      },
      table('t', weight: 1),
      keyValue('k'),
    ],
    'Row inside a Card': [
      {'id': 'root', 'component': 'Card', 'child': 'row'},
      {
        'id': 'row',
        'component': 'Row',
        'children': ['t', 'c'],
      },
      table('t'),
      chart('c'),
    ],
    'data components inside a List': [
      {
        'id': 'root',
        'component': 'List',
        'children': ['t', 'c', 'k'],
      },
      table('t'),
      chart('c'),
      keyValue('k'),
    ],
    'horizontal List of tables': [
      {
        'id': 'root',
        'component': 'List',
        'direction': 'horizontal',
        'children': ['t1', 't2'],
      },
      table('t1'),
      table('t2'),
    ],
  };

  for (final MapEntry(key: name, value: components) in layouts.entries) {
    testWidgets('lays out without errors: $name', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final registries = GenUiRegistries.empty();
      final controller = SurfaceController(
        catalogs: [buildDevToolsCatalog(registries)],
      );
      addTearDown(controller.dispose);
      parseSpec(
        jsonEncode([
          {
            'version': 'v0.9',
            'createSurface': {
              'surfaceId': 'main',
              'catalogId': devToolsCatalogId,
            },
          },
          {
            'version': 'v0.9',
            'updateComponents': {'surfaceId': 'main', 'components': components},
          },
        ]),
      ).forEach(controller.handleMessage);

      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(
            isDarkTheme: false,
            ideTheme: IdeTheme(),
            theme: ThemeData(),
          ),
          home: Scaffold(
            body: GenUiCanvas(
              surfaceController: controller,
              surfaceIds: const ['main'],
              actionDelegate: DevToolsActionDelegate(registries.actions),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
