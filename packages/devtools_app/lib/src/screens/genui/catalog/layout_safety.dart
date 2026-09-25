// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../data/json_utils.dart';

/// The width used by data components (tables, charts, ...) when they are
/// placed somewhere that doesn't bound their width, e.g. a horizontal `List`.
const defaultUnboundedDataComponentWidth = 400.0;

/// Makes the basic flex containers (`Row`, `Column`, `List`) tolerate layouts
/// that an agent is likely to generate but that Flutter can't lay out.
///
/// The GenUI canvas scrolls vertically, so the root `Column` has unbounded
/// height. A2UI `weight`s (and implicitly flexible components) become
/// [Flexible]s, which throw when the main axis is unbounded, and
/// `align: stretch` throws when the cross axis is unbounded. Such layout
/// exceptions leave the render tree in a bad state, so they cascade into
/// unrelated assertion failures on every subsequent frame.
///
/// The wrapped item checks its incoming constraints and, only when needed,
/// ignores weights / stretch alignment instead of throwing.
CatalogItem layoutSafeFlexItem(
  CatalogItem item, {
  required Axis Function(JsonObject data) mainAxis,
}) {
  return CatalogItem(
    name: item.name,
    dataSchema: item.dataSchema,
    exampleData: item.exampleData,
    isImplicitlyFlexible: item.isImplicitlyFlexible,
    widgetBuilder: (itemContext) => LayoutBuilder(
      builder: (context, constraints) {
        final data = (itemContext.data as Map).cast<String, Object?>();
        final axis = mainAxis(data);
        final mainBounded = axis == Axis.vertical
            ? constraints.hasBoundedHeight
            : constraints.hasBoundedWidth;
        final crossBounded = axis == Axis.vertical
            ? constraints.hasBoundedWidth
            : constraints.hasBoundedHeight;
        final dropStretch = !crossBounded && data['align'] == 'stretch';
        if (mainBounded && !dropStretch) {
          return item.widgetBuilder(itemContext);
        }
        return item.widgetBuilder(
          CatalogItemContext(
            data: dropStretch ? {...data, 'align': 'start'} : data,
            id: itemContext.id,
            type: itemContext.type,
            buildChild: itemContext.buildChild,
            dispatchEvent: itemContext.dispatchEvent,
            buildContext: context,
            dataContext: itemContext.dataContext,
            getComponent: mainBounded
                ? itemContext.getComponent
                : (id) => _withoutWeight(itemContext.getComponent(id)),
            getCatalogItem: mainBounded
                ? itemContext.getCatalogItem
                : (type) => _notFlexible(itemContext.getCatalogItem(type)),
            surfaceId: itemContext.surfaceId,
            reportError: itemContext.reportError,
          ),
        );
      },
    ),
  );
}

Component? _withoutWeight(Component? component) {
  if (component == null || !component.properties.containsKey('weight')) {
    return component;
  }
  return Component(
    id: component.id,
    type: component.type,
    properties: {...component.properties}..remove('weight'),
  );
}

final _notFlexibleItems = Expando<CatalogItem>();

CatalogItem? _notFlexible(CatalogItem? item) {
  if (item == null || !item.isImplicitlyFlexible) return item;
  return _notFlexibleItems[item] ??= CatalogItem(
    name: item.name,
    dataSchema: item.dataSchema,
    widgetBuilder: item.widgetBuilder,
  );
}

/// Returns [catalog] with its `Row`, `Column`, and `List` items made layout
/// safe (see [layoutSafeFlexItem]).
List<CatalogItem> layoutSafeBasicItems(Catalog catalog) {
  final mainAxes = <String, Axis Function(JsonObject data)>{
    'Row': (_) => Axis.horizontal,
    'Column': (_) => Axis.vertical,
    'List': (data) =>
        data['direction'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
  };
  return [
    for (final item in catalog.items)
      if (mainAxes[item.name] case final mainAxis?)
        layoutSafeFlexItem(item, mainAxis: mainAxis),
  ];
}

/// Gives [child] a default width when the incoming width is unbounded, so
/// data components like tables and charts (which expand to fill their width)
/// can be placed in horizontal lists and rows without a weight.
class BoundedWidth extends StatelessWidget {
  const BoundedWidth({
    super.key,
    this.width = defaultUnboundedDataComponentWidth,
    required this.child,
  });

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.hasBoundedWidth
          ? child
          : SizedBox(width: width, child: child),
    );
  }
}
