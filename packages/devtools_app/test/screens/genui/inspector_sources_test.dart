// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app/src/screens/genui/sources/default_registries.dart';
import 'package:devtools_app/src/screens/genui/sources/inspector_sources.dart';
import 'package:devtools_app/src/screens/inspector/inspector_data_models.dart';
import 'package:devtools_app/src/shared/console/eval/inspector_tree.dart';
import 'package:devtools_app/src/shared/diagnostics/diagnostics_node.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteDiagnosticsNode _node(
  String widget, {
  required String id,
  bool local = true,
  Map<String, Object?> extra = const {},
}) => RemoteDiagnosticsNode(
  {
    'description': widget,
    'widgetRuntimeType': widget,
    'valueId': id,
    'createdByLocalProject': local,
    if (local)
      'creationLocation': {
        'file': 'file:///app/lib/main.dart',
        'line': 10,
        'column': 5,
      },
    ...extra,
  },
  null,
  false,
  null,
);

RemoteDiagnosticsNode _property(String name, String value, {String? type}) =>
    RemoteDiagnosticsNode(
      {'name': name, 'description': value, 'propertyType': ?type},
      null,
      true,
      null,
    );

InspectorTreeNode _treeNode(
  RemoteDiagnosticsNode diagnostic, [
  List<InspectorTreeNode> children = const [],
]) {
  final node = InspectorTreeNode()..diagnostic = diagnostic;
  children.forEach(node.appendChild);
  return node;
}

void main() {
  group('projectWidgetTree', () {
    InspectorTreeNode tree() => _treeNode(_node('MyApp', id: 'a'), [
      _treeNode(_node('MaterialApp', id: 'b', local: false), [
        _treeNode(_node('HomePage', id: 'c'), [
          _treeNode(_node('Text', id: 'd')),
        ]),
      ]),
      _treeNode(_node('Padding', id: 'e')),
    ]);

    test('flattens depth first with depths and locations', () {
      final rows = projectWidgetTree(tree());
      expect(rows.map((r) => r['widget']), [
        'MyApp',
        'MaterialApp',
        'HomePage',
        'Text',
        'Padding',
      ]);
      expect(rows.map((r) => r['depth']), [0, 1, 2, 3, 1]);
      expect(rows.first, containsPair('id', 'a'));
      expect(rows.first, containsPair('file', 'file:///app/lib/main.dart'));
      expect(rows.first, containsPair('line', 10));
      expect(rows.first, containsPair('hasChildren', true));
      expect(rows[1], containsPair('isCreatedByLocalProject', false));
      expect(rows[1], containsPair('file', null));
    });

    test('localOnly skips framework widgets without counting depth', () {
      final rows = projectWidgetTree(tree(), localOnly: true);
      expect(rows.map((r) => r['widget']), [
        'MyApp',
        'HomePage',
        'Text',
        'Padding',
      ]);
      expect(rows.map((r) => r['depth']), [0, 1, 2, 1]);
    });

    test('honors maxDepth and limit', () {
      expect(projectWidgetTree(tree(), maxDepth: 1).map((r) => r['widget']), [
        'MyApp',
        'MaterialApp',
        'Padding',
      ]);
      expect(projectWidgetTree(tree(), limit: 2), hasLength(2));
      expect(projectWidgetTree(null), isEmpty);
    });

    test('reports the selected node', () {
      final root = tree();
      root.children.last.selected = true;
      final rows = projectWidgetTree(root);
      expect(rows.where((r) => r['selected'] == true).map((r) => r['id']), [
        'e',
      ]);
    });
  });

  group('projectInspectorSelection', () {
    test('is null without a selection', () {
      expect(
        projectInspectorSelection(null, (
          widgetProperties: const [],
          renderProperties: const [],
          layoutProperties: null,
          creationLocation: null,
        )),
        isNull,
      );
    });

    test('includes properties, render properties, and layout', () {
      final node = _node(
        'SizedBox',
        id: 's',
        extra: {
          'size': {'width': '100.0', 'height': '50.0'},
          'constraints': {
            'type': 'BoxConstraints',
            'minWidth': '0.0',
            'maxWidth': 'Infinity',
            'minHeight': '0.0',
            'maxHeight': '600.0',
          },
        },
      );
      final selection = projectInspectorSelection(node, (
        widgetProperties: [_property('width', '100.0')],
        renderProperties: [
          _property(
            'renderObject',
            'RenderConstrainedBox',
            type: 'RenderObject',
          ),
          _property('additionalConstraints', 'BoxConstraints(w=100.0)'),
        ],
        layoutProperties: LayoutProperties(node),
        creationLocation: null,
      ))!;
      expect(selection['id'], 's');
      expect(selection['widget'], 'SizedBox');
      expect(selection['location'], {
        'file': 'file:///app/lib/main.dart',
        'line': 10,
        'column': 5,
      });
      expect(selection['properties'], [
        {'name': 'width', 'value': '100.0', 'type': null},
      ]);
      expect(
        (selection['renderProperties'] as List).map((p) => (p as Map)['name']),
        ['additionalConstraints'],
      );
      final layout = selection['layout'] as Map;
      expect(layout['width'], 100.0);
      expect(layout['height'], 50.0);
      expect(layout['maxWidth'], isNull, reason: 'Infinity is not JSON');
      expect(layout['maxHeight'], 600.0);
    });
  });

  test('inspector sources and actions are registered', () {
    final registries = GenUiRegistries.defaults();
    for (final id in [
      'inspector.selection',
      'inspector.widgetTree',
      'inspector.status',
    ]) {
      expect(registries.dataSources.lookup(id), isNotNull, reason: id);
    }
    expect(
      registries.actions.lookup('inspector.selectWidget')!.mutatesApp,
      isFalse,
    );
    expect(registries.actions.lookup('inspector.refresh'), isNotNull);
    expect(
      registries.actions.lookup('inspector.setSelectMode')!.mutatesApp,
      isTrue,
    );
    expect(
      registries.actions.lookup('inspector.setOverlay')!.mutatesApp,
      isTrue,
    );
  });
}
