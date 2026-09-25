// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../shared/primitives/utils.dart';
import '../../../shared/table/table.dart';
import '../data/json_utils.dart';
import '../data/ref_store.dart';
import 'bound_value.dart';
import 'json_column_data.dart';
import 'layout_safety.dart';

/// Creates the `JsonTable` catalog item, a data-bound wrapper around
/// DevTools' [FlatTable].
CatalogItem jsonTableCatalogItem() => CatalogItem(
  name: 'JsonTable',
  dataSchema: S.object(
    description:
        'A sortable DevTools table of JSON rows. Selecting a row writes the '
        'row object to `selectionPath` (so other components, e.g. '
        'NetworkRequestDetails, can bind to it).',
    properties: {
      'rows': S.combined(
        description:
            'The rows: a data binding like {"path": "/requests"} to a list '
            'of objects (usually written by a DataSource), or a literal '
            'list.',
        anyOf: [
          A2uiSchemas.dataBindingSchema(),
          S.list(items: S.object(additionalProperties: true)),
        ],
      ),
      'preset': S.string(
        description:
            'Use a predefined set of columns for a known data source. Ignored '
            'if `columns` is set.',
        enumValues: jsonColumnPresets.keys.toList(),
      ),
      'columns': S.list(
        description: 'Columns to show, in order.',
        items: S.object(
          properties: {
            'field': S.string(
              description: 'Row field to show; dots traverse nested objects.',
            ),
            'title': S.string(),
            'format': S.string(
              enumValues: [for (final f in JsonColumnFormat.values) f.name],
              description:
                  'bytes: byte count; duration: milliseconds; timestamp: ms '
                  'since epoch; percent: ratio in [0,1].',
            ),
            'width': S.number(description: 'Width in pixels.'),
            'wide': S.boolean(
              description: 'Whether the column should take up extra space.',
            ),
          },
          required: ['field'],
        ),
      ),
      'selectionPath': S.string(
        description: 'Data model path to write the selected row to.',
      ),
      'defaultSortField': S.string(),
      'sortDescending': S.boolean(),
      'height': S.number(
        description: 'Height in pixels (default 300). Tables need a height.',
      ),
    },
    required: ['rows'],
  ),
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return BoundedWidth(
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['rows'],
        builder: (context, rows) => JsonTable(
          key: ValueKey('${itemContext.surfaceId}/${itemContext.id}'),
          tableId: '${itemContext.surfaceId}/${itemContext.id}',
          rows: [
            if (rows is List)
              for (final row in rows)
                if (row is Map) row.cast<String, Object?>(),
          ],
          columns: parseColumns(data),
          defaultSortField: data['defaultSortField'] as String?,
          sortDescending: data['sortDescending'] == true,
          height: (data['height'] as num?)?.toDouble() ?? 300,
          onSelected: switch (data['selectionPath']) {
            final String path when path.isNotEmpty =>
              (row) => itemContext.dataContext.update(DataPath(path), row),
            _ => null,
          },
        ),
      ),
    );
  },
);

/// Parses the `columns` or `preset` properties of a `JsonTable`.
///
/// Falls back to one column per key of the first row when neither is given.
List<JsonColumnData> parseColumns(Map<String, Object?> data) {
  final columns = data['columns'];
  final specs = columns is List && columns.isNotEmpty
      ? columns.whereType<Map>().map((c) => c.cast<String, Object?>())
      : jsonColumnPresets[data['preset']];
  if (specs == null) return const [];
  return [for (final spec in specs) JsonColumnData.fromJson(spec)];
}

/// A [FlatTable] of JSON rows.
class JsonTable extends StatefulWidget {
  const JsonTable({
    super.key,
    required this.tableId,
    required this.rows,
    required this.columns,
    this.defaultSortField,
    this.sortDescending = false,
    this.height = 300,
    this.onSelected,
  });

  final String tableId;
  final List<JsonObject> rows;

  /// The columns. If empty, columns are inferred from the first row.
  final List<JsonColumnData> columns;
  final String? defaultSortField;
  final bool sortDescending;
  final double height;
  final void Function(JsonObject? row)? onSelected;

  @override
  State<JsonTable> createState() => _JsonTableState();
}

class _JsonTableState extends State<JsonTable> {
  final _selection = ValueNotifier<JsonObject?>(null);

  @override
  void didUpdateWidget(JsonTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rows are re-created on every data source emission; keep the selection
    // pointing at the equivalent row.
    final selected = _selection.value;
    if (selected != null && !widget.rows.contains(selected)) {
      final key = _rowIdentity(selected);
      _selection.value = widget.rows
          .where((r) => _rowIdentity(r) == key)
          .firstOrNull;
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  static Object? _rowIdentity(JsonObject row) => row[refKey] ?? row['id'];

  @override
  Widget build(BuildContext context) {
    var columns = widget.columns;
    if (columns.isEmpty) {
      final first = widget.rows.firstOrNull;
      columns = [
        for (final key in first?.keys ?? const <String>[])
          if (key != refKey) JsonColumnData(title: key, field: key),
      ];
    }
    if (columns.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: const Center(child: Text('No data')),
      );
    }
    final sortColumn =
        columns.where((c) => c.field == widget.defaultSortField).firstOrNull ??
        columns.first;
    return SizedBox(
      height: widget.height,
      child: FlatTable<JsonObject>(
        keyFactory: (row) =>
            ValueKey<Object>(_rowIdentity(row) ?? identityHashCode(row)),
        data: widget.rows,
        dataKey: 'genui/${widget.tableId}',
        columns: columns,
        defaultSortColumn: sortColumn,
        defaultSortDirection: widget.sortDescending
            ? SortDirection.descending
            : SortDirection.ascending,
        selectionNotifier: _selection,
        onItemSelected: widget.onSelected,
      ),
    );
  }
}
