// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:devtools_app/src/screens/genui/catalog/action_delegate.dart';
import 'package:devtools_app/src/screens/genui/catalog/devtools_catalog.dart';
import 'package:devtools_app/src/screens/genui/data/data_source.dart';
import 'package:devtools_app/src/screens/genui/genui_spec.dart';
import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app_shared/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:material_ui/material_ui.dart';

/// End-to-end test: a saved spec (no LLM) rendered with the DevTools catalog,
/// with live data flowing from a data source through JMESPath into
/// components.
void main() {
  testWidgets('replays a spec with a DataSource-bound KeyValue card', (
    tester,
  ) async {
    final registries = GenUiRegistries.empty();
    registries.dataSources.register(
      DataSourceDescriptor(
        id: 'test.vm',
        description: 'Fake VM info.',
        paramsSchema: S.object(properties: {}),
        outputSchema: S.object(),
        open: (context, params) => Stream.value({
          'name': 'vm',
          'version': '3.9.0 (stable)',
          'pid': 42,
        }),
      ),
    );
    final controller = SurfaceController(
      catalogs: [buildDevToolsCatalog(registries)],
    );
    addTearDown(controller.dispose);

    final spec = jsonEncode([
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 'main', 'catalogId': devToolsCatalogId},
      },
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': 'main',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['source', 'card'],
            },
            {
              'id': 'source',
              'component': 'DataSource',
              'source': 'test.vm',
              'expression': '{Version: version, PID: pid}',
              'targetPath': '/vm',
            },
            {
              'id': 'card',
              'component': 'KeyValue',
              'title': 'VM',
              'value': {'path': '/vm'},
            },
          ],
        },
      },
    ]);
    parseSpec(spec).forEach(controller.handleMessage);

    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(
          isDarkTheme: false,
          ideTheme: IdeTheme(),
          theme: ThemeData(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Surface(
              surfaceContext: controller.contextFor('main'),
              actionDelegate: DevToolsActionDelegate(registries.actions),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('VM'), findsOneWidget);
    expect(find.text('Version:'), findsOneWidget);
    expect(find.text('3.9.0 (stable)'), findsOneWidget);
    expect(find.text('PID:'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    // The data source is non-visual when healthy.
    expect(find.textContaining('error'), findsNothing);

    // Specs round trip.
    final exported = surfacesToSpec([
      controller.contextFor('main').definition.value!,
    ]);
    expect((exported['messages'] as List).map((m) => (m as Map).keys.last), [
      'createSurface',
      'updateComponents',
    ]);
  });
}
