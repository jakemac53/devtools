// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../shared/charts/chart.dart';
import '../../../shared/charts/chart_controller.dart';
import '../../../shared/charts/chart_trace.dart' as chart_trace;
import '../data/json_utils.dart';
import 'bound_value.dart';
import 'layout_safety.dart';

/// Creates the `TimeSeriesChart` catalog item, a data-bound wrapper around
/// DevTools' live [Chart] (the one used by the Memory screen).
CatalogItem timeSeriesChartCatalogItem() => CatalogItem(
  name: 'TimeSeriesChart',
  dataSchema: S.object(
    description:
        'A live DevTools line chart. `data` is a list of objects with a '
        'millisecond timestamp field and one numeric field per series. New '
        'rows (with larger timestamps) are appended incrementally.',
    properties: {
      'data': S.combined(
        description: 'A data binding (e.g. {"path": "/samples"}) or list.',
        anyOf: [
          A2uiSchemas.dataBindingSchema(),
          S.list(items: S.object(additionalProperties: true)),
        ],
      ),
      'timestampField': S.string(
        description: 'Field holding ms since epoch (default "timestamp").',
      ),
      'series': S.list(
        items: S.object(
          properties: {
            'field': S.string(),
            'label': S.string(),
            'color': S.string(description: 'Hex color, e.g. "#33b5e5".'),
            'stacked': S.boolean(),
          },
          required: ['field'],
        ),
      ),
      'title': S.string(),
      'height': S.number(description: 'Height in pixels (default 150).'),
    },
    required: ['data', 'series'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Column",
          "children": ["heapSource", "heapChart"]
        },
        {
          "id": "heapSource",
          "component": "DataSource",
          "source": "memory.heapSamples",
          "targetPath": "/heap"
        },
        {
          "id": "heapChart",
          "component": "TimeSeriesChart",
          "data": {"path": "/heap"},
          "series": [
            {"field": "used", "label": "Used", "stacked": true},
            {"field": "capacity", "label": "Capacity"}
          ]
        }
      ]
    ''',
  ],
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final series = [
      for (final s in (data['series'] as List? ?? const []).whereType<Map>())
        if (s['field'] is String) ChartSeries.fromJson(s.cast()),
    ];
    return BoundedWidth(
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['data'],
        builder: (context, rows) => TimeSeriesChart(
          key: ValueKey('${itemContext.surfaceId}/${itemContext.id}'),
          rows: [
            if (rows is List)
              for (final r in rows)
                if (r is Map) r.cast<String, Object?>(),
          ],
          series: series,
          timestampField: data['timestampField'] as String? ?? 'timestamp',
          title: data['title'] as String? ?? '',
          height: (data['height'] as num?)?.toDouble() ?? 150,
        ),
      ),
    );
  },
);

/// A single line in a [TimeSeriesChart].
class ChartSeries {
  const ChartSeries({
    required this.field,
    this.label,
    this.color,
    this.stacked = false,
  });

  factory ChartSeries.fromJson(JsonObject json) => ChartSeries(
    field: json['field'] as String,
    label: json['label'] as String?,
    color: parseHexColor(json['color']),
    stacked: json['stacked'] == true,
  );

  final String field;
  final String? label;
  final Color? color;
  final bool stacked;

  @override
  bool operator ==(Object other) =>
      other is ChartSeries &&
      other.field == field &&
      other.label == label &&
      other.color == color &&
      other.stacked == stacked;

  @override
  int get hashCode => Object.hash(field, label, color, stacked);
}

/// Parses `#rrggbb` or `#aarrggbb`.
Color? parseHexColor(Object? value) {
  if (value is! String) return null;
  var hex = value.replaceFirst('#', '');
  if (hex.length == 6) hex = 'ff$hex';
  final parsed = int.tryParse(hex, radix: 16);
  return hex.length == 8 && parsed != null ? Color(parsed) : null;
}

const _palette = [
  Color(0xff33b5e5),
  Color(0xffff9800),
  Color(0xff4caf50),
  Color(0xffe91e63),
  Color(0xff9c27b0),
  Color(0xff795548),
];

/// A live chart of JSON rows.
class TimeSeriesChart extends StatefulWidget {
  const TimeSeriesChart({
    super.key,
    required this.rows,
    required this.series,
    this.timestampField = 'timestamp',
    this.title = '',
    this.height = 150,
  });

  final List<JsonObject> rows;
  final List<ChartSeries> series;
  final String timestampField;
  final String title;
  final double height;

  @override
  State<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends State<TimeSeriesChart> {
  late JsonChartController _controller;

  @override
  void initState() {
    super.initState();
    _controller = JsonChartController(widget.series, widget.timestampField)
      ..sync(widget.rows);
  }

  @override
  void didUpdateWidget(TimeSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_listEquals(oldWidget.series, widget.series) ||
        oldWidget.timestampField != widget.timestampField) {
      _controller.dispose();
      _controller = JsonChartController(widget.series, widget.timestampField);
    }
    _controller.sync(widget.rows);
  }

  static bool _listEquals(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.series.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: const Center(child: Text('No series configured')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: denseSpacing),
          child: Wrap(
            spacing: defaultSpacing,
            children: [
              if (widget.title.isNotEmpty)
                Text(widget.title, style: Theme.of(context).boldTextStyle),
              for (final (i, s) in widget.series.indexed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      color: JsonChartController.colorFor(s, i),
                    ),
                    const SizedBox(width: densePadding),
                    Text(s.label ?? s.field),
                  ],
                ),
            ],
          ),
        ),
        SizedBox(height: widget.height, child: Chart(_controller)),
      ],
    );
  }
}

/// A [ChartController] that plots numeric fields of JSON rows.
@visibleForTesting
class JsonChartController extends ChartController {
  JsonChartController(this.series, this.timestampField)
    : super(name: 'GenUI chart') {
    for (final (i, s) in series.indexed) {
      createTrace(
        chart_trace.ChartType.line,
        chart_trace.PaintCharacteristics(
          color: colorFor(s, i),
          symbol: chart_trace.ChartSymbol.disc,
          diameter: 1.5,
        ),
        name: s.label ?? s.field,
        stacked: s.stacked,
      );
    }
  }

  static Color colorFor(ChartSeries s, int index) =>
      s.color ?? _palette[index % _palette.length];

  final List<ChartSeries> series;
  final String timestampField;

  int? _lastTimestamp;

  /// Appends rows newer than the last plotted row. If the data went
  /// backwards (e.g. the source was cleared) the chart is reset.
  void sync(List<JsonObject> rows) {
    if (rows.isEmpty) return;
    final last = _lastTimestamp;
    if (last != null && rows.every((r) => (_timestampOf(r) ?? 0) < last)) {
      reset();
      _lastTimestamp = null;
    }
    for (final row in rows) {
      final ts = _timestampOf(row);
      if (ts == null) continue;
      if (_lastTimestamp != null && ts <= _lastTimestamp!) continue;
      addTimestamp(ts);
      for (final (i, s) in series.indexed) {
        final value = row[s.field];
        addDataToTrace(
          i,
          chart_trace.Data(ts, value is num ? value.toDouble() : 0),
        );
      }
      _lastTimestamp = ts;
    }
  }

  int? _timestampOf(JsonObject row) => (row[timestampField] as num?)?.toInt();
}
