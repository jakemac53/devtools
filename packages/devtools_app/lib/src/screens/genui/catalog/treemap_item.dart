// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../shared/charts/treemap.dart';
import '../data/json_utils.dart';
import 'bound_value.dart';
import 'json_column_data.dart';
import 'layout_safety.dart';
import 'simple_charts_item.dart';
import 'time_series_chart_item.dart';

/// The label used for rows whose group field is missing.
const _noneLabel = '(none)';

/// The label for a node's own value beyond the sum of its children.
const _selfLabel = '<self>';

/// The label for children grouped together beyond `maxChildren`.
const _otherLabel = 'Other';

class _Group {
  _Group(this.name);

  final String name;
  final children = <String, _Group>{};
  double value = 0;

  _Group child(String name) => children.putIfAbsent(name, () => _Group(name));

  /// Sets [value] to the sum of the children (recursively) where that is
  /// larger, and records any own value beyond that as a [_selfLabel] child.
  void normalize({required double ownValue}) {
    var sum = 0.0;
    for (final child in children.values) {
      sum += child.value;
    }
    if (children.isNotEmpty && ownValue > sum) {
      child(_selfLabel).value += ownValue - sum;
      sum = ownValue;
    }
    value = children.isEmpty ? ownValue : sum;
  }
}

double _positive(Object? value) =>
    value is num && value > 0 ? value.toDouble() : 0;

/// Adds a child to [group] for each hierarchical row in [rows] that has a
/// positive size.
void _addHierarchyChildren(
  _Group group,
  Object? rows, {
  required String labelField,
  required String valueField,
  required String childrenField,
}) {
  if (rows is! List) return;
  for (final row in rows) {
    final child = _fromHierarchy(
      row,
      labelField: labelField,
      valueField: valueField,
      childrenField: childrenField,
    );
    if (child.value <= 0) continue;
    // Keep siblings with the same label apart.
    var name = child.name;
    for (var i = 2; group.children.containsKey(name); i++) {
      name = '${child.name} ($i)';
    }
    group.children[name] = name == child.name
        ? child
        : (_Group(name)
            ..value = child.value
            ..children.addAll(child.children));
  }
}

_Group _fromHierarchy(
  Object? row, {
  required String labelField,
  required String valueField,
  required String childrenField,
}) {
  final group = _Group(readJsonField(row, labelField)?.toString() ?? '');
  _addHierarchyChildren(
    group,
    readJsonField(row, childrenField),
    labelField: labelField,
    valueField: valueField,
    childrenField: childrenField,
  );
  group.normalize(ownValue: _positive(readJsonField(row, valueField)));
  return group;
}

/// Builds the [TreemapNode] tree shown by the `TreeMap` component.
///
/// [rows] is either:
///  * a flat list of rows, grouped into nested rectangles by the fields in
///    [groupBy] (outermost first), with one leaf per row labeled by
///    [labelField]; or
///  * when [groupBy] is empty, a list of hierarchical rows whose children are
///    in [childrenField]. A node's size is its [valueField] or, if larger,
///    the sum of its children.
///
/// Rows without a positive numeric value are skipped. Each node keeps at most
/// [maxChildren] children; the rest are grouped into an "Other" node.
@visibleForTesting
TreemapNode buildGenUiTreemap(
  Object? rows, {
  required String rootName,
  String labelField = 'name',
  String valueField = 'value',
  List<String> groupBy = const [],
  String childrenField = 'children',
  JsonColumnFormat format = JsonColumnFormat.number,
  int maxChildren = 50,
}) {
  final root = _Group(rootName);
  if (rows is List) {
    if (groupBy.isEmpty) {
      _addHierarchyChildren(
        root,
        rows,
        labelField: labelField,
        valueField: valueField,
        childrenField: childrenField,
      );
    } else {
      for (final row in rows) {
        final value = _positive(readJsonField(row, valueField));
        if (value <= 0) continue;
        var group = root;
        for (final field in groupBy) {
          group = group.child(
            readJsonField(row, field)?.toString() ?? _noneLabel,
          );
        }
        group.child(readJsonField(row, labelField)?.toString() ?? '').value +=
            value;
      }
      void sumUp(_Group group) {
        if (group.children.isEmpty) return; // Leaves keep their own value.
        group.children.values.forEach(sumUp);
        group.normalize(ownValue: 0);
      }

      sumUp(root);
    }
    root.normalize(ownValue: 0);
  }

  // Sizes are integers, so scale fractional values (e.g. milliseconds or
  // percentages) to keep their proportions.
  final scale = format == JsonColumnFormat.bytes ? 1 : 1000;
  String formatSize(int size) => formatJsonValue(size / scale, format);

  TreemapNode convert(_Group group, Color? color) {
    final sorted = group.children.values.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var children = sorted;
    if (sorted.length > maxChildren) {
      final keep = maxChildren < 2 ? 1 : maxChildren - 1;
      final other = _Group(_otherLabel)
        ..value = sorted.skip(keep).fold(0.0, (sum, g) => sum + g.value);
      children = [...sorted.take(keep), other];
    }
    final node = TreemapNode(
      name: group.name,
      byteSize: (group.value * scale).round(),
      backgroundColor: color,
      sizeFormatter: formatSize,
    );
    for (final (index, child) in children.indexed) {
      final childColor =
          color ??
          Color.lerp(
            genUiChartPalette[index % genUiChartPalette.length],
            Colors.white,
            0.35,
          );
      final childNode = convert(child, childColor);
      if (childNode.byteSize > 0) node.addChild(childNode);
    }
    return node;
  }

  return convert(root, null);
}

/// Creates the `TreeMap` catalog item: nested rectangles sized by value,
/// built on the treemap used by the App Size and VM Tools screens.
CatalogItem treemapCatalogItem() => CatalogItem(
  name: 'TreeMap',
  dataSchema: S.object(
    description:
        'Treemap: nested rectangles sized by value, for hierarchical '
        'breakdowns such as memory by package > library > class or CPU time '
        'by package > function. Click a rectangle to zoom in and use the '
        'breadcrumbs to zoom out. Give flat rows plus `groupBy` fields '
        '(outermost first), or hierarchical rows with a `children` list.',
    properties: {
      'data': S.combined(
        description: 'A data binding (e.g. {"path": "/classes"}) or list.',
        anyOf: [
          A2uiSchemas.dataBindingSchema(),
          S.list(items: S.object(additionalProperties: true)),
        ],
      ),
      'valueField': S.string(
        description: 'Numeric field for rectangle size (default "value").',
      ),
      'labelField': S.string(
        description: 'Field holding each leaf\'s label (default "name").',
      ),
      'groupBy': S.list(
        description:
            'Fields to group flat rows by, outermost first, e.g. '
            '["package", "library"]. Dots traverse nested fields.',
        items: S.string(),
      ),
      'childrenField': S.string(
        description:
            'For hierarchical rows (no `groupBy`): the field holding child '
            'rows (default "children").',
      ),
      'format': S.string(
        description: 'How to format sizes (default "number").',
        enumValues: [for (final f in JsonColumnFormat.values) f.name],
      ),
      'title': S.string(description: 'Name of the root rectangle.'),
      'maxChildren': S.integer(
        description:
            'Maximum rectangles per level; the rest are grouped into '
            '"Other" (default 50).',
        minimum: 2,
      ),
      'height': S.number(description: 'Height in pixels (default 400).'),
    },
    required: ['data'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Column",
          "children": ["classesSource", "classesTreemap"]
        },
        {
          "id": "classesSource",
          "component": "DataSource",
          "source": "memory.classes",
          "expression": "[:500]",
          "targetPath": "/classes"
        },
        {
          "id": "classesTreemap",
          "component": "TreeMap",
          "title": "Dart heap",
          "data": {"path": "/classes"},
          "groupBy": ["package", "library"],
          "labelField": "class",
          "valueField": "totalBytes",
          "format": "bytes"
        }
      ]
    ''',
  ],
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    final groupBy = data['groupBy'];
    return BoundedWidth(
      child: SizedBox(
        height: (data['height'] as num?)?.toDouble() ?? 400,
        child: ResolvedValueBuilder(
          dataContext: itemContext.dataContext,
          value: data['data'],
          builder: (context, rows) => GenUiTreemap(
            root: buildGenUiTreemap(
              rows,
              rootName: data['title'] as String? ?? 'Total',
              labelField: data['labelField'] as String? ?? 'name',
              valueField: data['valueField'] as String? ?? 'value',
              groupBy: groupBy is List
                  ? [for (final field in groupBy) field.toString()]
                  : const [],
              childrenField: data['childrenField'] as String? ?? 'children',
              format: JsonColumnFormat.parse(data['format'] ?? 'number'),
              maxChildren: (data['maxChildren'] as num?)?.toInt() ?? 50,
            ),
          ),
        ),
      ),
    );
  },
);

/// Shows [root] in a zoomable [Treemap], keeping the zoomed-in node across
/// data updates when it still exists.
class GenUiTreemap extends StatefulWidget {
  const GenUiTreemap({super.key, required this.root});

  final TreemapNode root;

  @override
  State<GenUiTreemap> createState() => _GenUiTreemapState();
}

class _GenUiTreemapState extends State<GenUiTreemap> {
  /// Names from the root (exclusive) to the zoomed-in node.
  var _zoomPath = const <String>[];

  TreemapNode _zoomedNode() {
    var node = widget.root;
    for (final name in _zoomPath) {
      final child = node.children.where((c) => c.name == name).firstOrNull;
      if (child == null) break;
      node = child;
    }
    return node;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.root.byteSize <= 0) {
      return RoundedOutlinedBorder(
        child: Center(
          child: Text('No data', style: Theme.of(context).subtleTextStyle),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Treemap.fromRoot(
        rootNode: _zoomedNode(),
        levelsVisible: 2,
        isOutermostLevel: true,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        onRootChangedCallback: (node) => setState(() {
          _zoomPath = node == null
              ? const []
              : [for (final n in node.pathFromRoot().skip(1)) n.name];
        }),
      ),
    );
  }
}
