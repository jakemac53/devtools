// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../vm_developer/vm_developer_common_widgets.dart';
import '../data/ref_store.dart';
import 'bound_value.dart';
import 'json_column_data.dart';
import 'layout_safety.dart';

/// Creates the `KeyValue` catalog item, which renders an object as a DevTools
/// info card (the same [VMInfoCard] the VM Tools screen uses).
CatalogItem keyValueCatalogItem() => CatalogItem(
  name: 'KeyValue',
  dataSchema: S.object(
    description:
        'A DevTools info card showing the fields of an object as labeled '
        'rows.',
    properties: {
      'title': S.string(),
      'value': S.combined(
        description:
            'A data binding (e.g. {"path": "/vm"}) to an object, or a '
            'literal object.',
        anyOf: [
          A2uiSchemas.dataBindingSchema(),
          S.object(additionalProperties: true),
        ],
      ),
      'fields': S.list(
        description:
            'Optional fields to show, in order. Defaults to all fields of '
            'the object.',
        items: S.object(
          properties: {
            'field': S.string(),
            'label': S.string(),
            'format': S.string(
              enumValues: [for (final f in JsonColumnFormat.values) f.name],
            ),
          },
          required: ['field'],
        ),
      ),
    },
    required: ['title', 'value'],
  ),
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final fields = [
      for (final f in (data['fields'] as List? ?? const []).whereType<Map>())
        if (f['field'] is String) f.cast<String, Object?>(),
    ];
    return BoundedWidth(
      width: 320,
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['value'],
        builder: (context, value) => VMInfoCard(
          title: data['title'] as String? ?? '',
          rowKeyValues: keyValueRows(
            value is Map ? value.cast<String, Object?>() : const {},
            fields,
          ),
        ),
      ),
    );
  },
);

/// Builds the rows of a `KeyValue` card.
List<MapEntry<String, WidgetBuilder>> keyValueRows(
  Map<String, Object?> value,
  List<Map<String, Object?>> fields,
) {
  final specs = fields.isNotEmpty
      ? fields
      : [
          for (final key in value.keys)
            if (key != refKey) {'field': key},
        ];
  return [
    for (final spec in specs)
      selectableTextBuilderMapEntry(
        spec['label'] as String? ?? spec['field'] as String,
        formatJsonValue(
          value[spec['field']],
          JsonColumnFormat.parse(spec['format']),
        ),
      ),
  ];
}
