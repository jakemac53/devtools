// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:genui/genui.dart';

import '../sources/default_registries.dart';
import 'data_source_item.dart';
import 'json_table_item.dart';
import 'key_value_item.dart';
import 'layout_safety.dart';
import 'network_request_details_item.dart';
import 'simple_charts_item.dart';
import 'time_series_chart_item.dart';

/// The catalog id for the DevTools GenUI catalog.
const devToolsCatalogId = 'https://flutter.dev/devtools/genui/catalog/v1';

/// Guidance for the agent on how to use the DevTools specific components.
const devToolsCatalogPromptFragment = '''
# DevTools components

You build DevTools screens for a developer debugging a running Dart or
Flutter app. Live data NEVER goes into your messages directly. Instead:

1. Discover data with the `listDataSources`, `describeDataSource` and
   `previewDataSource` tools, and actions with `listActions` /
   `describeAction`.
2. Add a non-visual `DataSource` component that streams a source into the
   data model at `targetPath`. Use its JMESPath `expression` to filter, sort,
   project or aggregate the data (e.g. `[?didFail]`,
   `sort_by(@, &durationMs)[-10:]`, `length(@)`,
   `[].{uri: uri, ms: durationMs, _ref: _ref}`). Validate expressions with
   `previewDataSource` first.
3. Bind visual components (`JsonTable`, `TimeSeriesChart`, `BarChart`,
   `PieChart`, `Stat`, `KeyValue`, `Text`, ...) to `targetPath` with
   `{"path": "..."}` bindings. Use `TimeSeriesChart` for values over time,
   `BarChart` for ranked top-N rows, `PieChart` for shares of a total, and
   `Stat` for headline numbers (several in a `Row` make a dashboard).
4. For master/detail, give a `JsonTable` a `selectionPath` and bind a detail
   component (or a `DataSource` param) to that path.
5. Keep `_ref` fields when projecting rows that feed composite components like
   `NetworkRequestDetails`.
6. To let the user run a DevTools action, use a `Button` whose action is
   `{"event": {"name": "<action id>", "context": {...args}}}`. Actions run
   locally in DevTools; actions that change the app ask the user for
   confirmation first.

Every `DataSource` must be part of the component tree (e.g. a child of the
root `Column`) to be active.

Layout: the canvas scrolls vertically, so vertical space is unbounded. Size
tables, charts and details panes with `height` (they have sensible defaults);
`weight` is ignored for children of vertical `Column`s. To place things side by
side use a `Row`: tables, charts and details panes share its width
automatically, and `weight` sets their relative widths.
''';

/// Builds the catalog used by the GenUI screen: the A2UI basic catalog plus
/// the DevTools data-bound components.
Catalog buildDevToolsCatalog(GenUiRegistries registries) {
  final basic = BasicCatalogItems.asCatalog();
  return basic.copyWith(
    catalogId: devToolsCatalogId,
    catalogIdAliases: [?basic.catalogId],
    newItems: [
      ...layoutSafeBasicItems(basic),
      dataSourceCatalogItem(registries.dataSources),
      jsonTableCatalogItem(),
      timeSeriesChartCatalogItem(),
      keyValueCatalogItem(),
      networkRequestDetailsCatalogItem(registries.refs),
      barChartCatalogItem(),
      pieChartCatalogItem(),
      statCatalogItem(),
    ],
    systemPromptFragments: [
      ...basic.systemPromptFragments,
      devToolsCatalogPromptFragment,
    ],
  );
}
