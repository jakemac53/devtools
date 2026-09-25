// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:math' as math;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../data/json_utils.dart';
import 'bound_value.dart';
import 'json_column_data.dart';
import 'layout_safety.dart';
import 'time_series_chart_item.dart';

/// Reads [field] from [row]; dots traverse nested maps (e.g. `stats.bytes`).
@visibleForTesting
Object? readJsonField(Object? row, String field) {
  Object? current = row;
  for (final segment in field.split('.')) {
    if (current is! Map) return null;
    current = current[segment];
  }
  return current;
}

/// A labeled numeric value, e.g. one bar or pie slice.
@immutable
class LabeledValue {
  const LabeledValue(this.label, this.value);

  final String label;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is LabeledValue && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);

  @override
  String toString() => '$label: $value';
}

/// Extracts `(label, value)` pairs from [rows], skipping rows whose value is
/// not a number. Keeps the row order.
@visibleForTesting
List<LabeledValue> labeledValues(
  Object? rows, {
  required String labelField,
  required String valueField,
}) {
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (readJsonField(row, valueField) case final num value)
        LabeledValue(
          readJsonField(row, labelField)?.toString() ?? '',
          value.toDouble(),
        ),
  ];
}

/// Returns the slices for a pie chart: positive values only, largest first,
/// with everything beyond the largest `maxSlices - 1` grouped into "Other".
@visibleForTesting
List<LabeledValue> pieSlices(List<LabeledValue> values, {int maxSlices = 8}) {
  final positive = values.where((v) => v.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (positive.length <= maxSlices) return positive;
  final keep = math.max(1, maxSlices - 1);
  final other = positive.skip(keep).fold<double>(0, (sum, v) => sum + v.value);
  return [...positive.take(keep), LabeledValue('Other', other)];
}

/// Reads a list of numbers from [history]: either a list of numbers, or a
/// list of rows with a numeric [field].
@visibleForTesting
List<double> numericSeries(Object? history, {String? field}) {
  if (history is! List) return const [];
  return [
    for (final item in history)
      if (field == null ? item : readJsonField(item, field) case final num v)
        v.toDouble(),
  ];
}

JsonColumnFormat _formatOf(JsonObject data) =>
    JsonColumnFormat.parse(data['format'] ?? 'number');

Schema _dataSchema(String description) => S.combined(
  description: description,
  anyOf: [
    A2uiSchemas.dataBindingSchema(),
    S.list(items: S.object(additionalProperties: true)),
  ],
);

Schema get _formatSchema => S.string(
  description: 'How to format values (default "number").',
  enumValues: [for (final f in JsonColumnFormat.values) f.name],
);

Widget _title(BuildContext context, String? title) => title == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(bottom: densePadding),
        child: Text(title, style: Theme.of(context).boldTextStyle),
      );

Widget _noData(BuildContext context) =>
    Text('No data', style: Theme.of(context).subtleTextStyle);

/// Creates the `BarChart` catalog item: horizontal bars for category/value
/// rows, e.g. the top functions by CPU time or classes by memory.
CatalogItem barChartCatalogItem() => CatalogItem(
  name: 'BarChart',
  dataSchema: S.object(
    description:
        'Horizontal bar chart of rows, one bar per row (in row order; sort '
        'and limit with a DataSource expression). Good for top-N lists and '
        'category breakdowns.',
    properties: {
      'data': _dataSchema('A data binding (e.g. {"path": "/top"}) or list.'),
      'labelField': S.string(
        description: 'Field holding each bar\'s label (default "name").',
      ),
      'valueField': S.string(description: 'Numeric field for bar length.'),
      'format': _formatSchema,
      'title': S.string(),
      'color': S.string(description: 'Hex color, e.g. "#33b5e5".'),
      'maxBars': S.integer(
        description: 'Maximum number of bars (default 20).',
        minimum: 1,
      ),
    },
    required: ['data', 'valueField'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Column",
          "children": ["classesSource", "classesChart"]
        },
        {
          "id": "classesSource",
          "component": "DataSource",
          "source": "memory.classes",
          "expression": "[:10]",
          "targetPath": "/classes"
        },
        {
          "id": "classesChart",
          "component": "BarChart",
          "title": "Largest classes",
          "data": {"path": "/classes"},
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
    return BoundedWidth(
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['data'],
        builder: (context, rows) => SimpleBarChart(
          values: labeledValues(
            rows,
            labelField: data['labelField'] as String? ?? 'name',
            valueField: data['valueField'] as String? ?? 'value',
          ).take((data['maxBars'] as num?)?.toInt() ?? 20).toList(),
          format: _formatOf(data),
          title: data['title'] as String?,
          color: parseHexColor(data['color']),
        ),
      ),
    );
  },
);

/// Horizontal bars with labels and formatted values.
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({
    super.key,
    required this.values,
    this.format = JsonColumnFormat.number,
    this.title,
    this.color,
  });

  final List<LabeledValue> values;
  final JsonColumnFormat format;
  final String? title;
  final Color? color;

  static const _barHeight = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxValue = values.fold<double>(0, (m, v) => math.max(m, v.value));
    final barColor = color ?? genUiChartPalette.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _title(context, title),
        if (values.isEmpty) _noData(context),
        for (final v in values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    v.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.regularTextStyle,
                  ),
                ),
                const SizedBox(width: densePadding),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: maxValue <= 0
                          ? 0
                          : (v.value / maxValue).clamp(0.0, 1.0),
                      child: Container(
                        height: _barHeight,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: densePadding),
                SizedBox(
                  width: 80,
                  child: Text(
                    formatJsonValue(v.value, format),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.regularTextStyle,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Creates the `PieChart` catalog item: a donut chart with a legend.
CatalogItem pieChartCatalogItem() => CatalogItem(
  name: 'PieChart',
  dataSchema: S.object(
    description:
        'Donut chart with a legend showing each row\'s share of the total. '
        'Slices are sorted largest first; beyond `maxSlices` the rest are '
        'grouped into "Other". Good for breakdowns like CPU time by '
        'category or memory by package.',
    properties: {
      'data': _dataSchema(
        'A data binding (e.g. {"path": "/byCategory"}) or list of rows.',
      ),
      'labelField': S.string(
        description: 'Field holding each slice\'s label (default "name").',
      ),
      'valueField': S.string(description: 'Numeric field for slice size.'),
      'format': _formatSchema,
      'title': S.string(),
      'maxSlices': S.integer(
        description: 'Maximum number of slices (default 8).',
        minimum: 2,
      ),
      'size': S.number(description: 'Chart diameter in pixels (default 140).'),
    },
    required: ['data', 'valueField'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Column",
          "children": ["cpuSource", "cpuPie"]
        },
        {
          "id": "cpuSource",
          "component": "DataSource",
          "source": "cpu.activity",
          "expression": "[{name: 'app', value: sum([].app)}, {name: 'flutter', value: sum([].flutter)}, {name: 'dart', value: sum([].dart)}, {name: 'native', value: sum([].native)}]",
          "targetPath": "/byCategory"
        },
        {
          "id": "cpuPie",
          "component": "PieChart",
          "title": "CPU samples by category",
          "data": {"path": "/byCategory"},
          "valueField": "value"
        }
      ]
    ''',
  ],
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    return BoundedWidth(
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['data'],
        builder: (context, rows) => SimplePieChart(
          slices: pieSlices(
            labeledValues(
              rows,
              labelField: data['labelField'] as String? ?? 'name',
              valueField: data['valueField'] as String? ?? 'value',
            ),
            maxSlices: (data['maxSlices'] as num?)?.toInt() ?? 8,
          ),
          format: _formatOf(data),
          title: data['title'] as String?,
          size: (data['size'] as num?)?.toDouble() ?? 140,
        ),
      ),
    );
  },
);

/// A donut chart with a legend.
class SimplePieChart extends StatelessWidget {
  const SimplePieChart({
    super.key,
    required this.slices,
    this.format = JsonColumnFormat.number,
    this.title,
    this.size = 140,
  });

  final List<LabeledValue> slices;
  final JsonColumnFormat format;
  final String? title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = slices.fold<double>(0, (sum, s) => sum + s.value);
    final colors = [
      for (var i = 0; i < slices.length; i++)
        genUiChartPalette[i % genUiChartPalette.length],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _title(context, title),
        if (slices.isEmpty)
          _noData(context)
        else
          Row(
            children: [
              SizedBox.square(
                dimension: size,
                child: CustomPaint(
                  painter: _DonutPainter(
                    values: [for (final s in slices) s.value],
                    colors: colors,
                    background: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: defaultSpacing),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < slices.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Container(width: 10, height: 10, color: colors[i]),
                            const SizedBox(width: densePadding),
                            Expanded(
                              child: Text(
                                slices[i].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.regularTextStyle,
                              ),
                            ),
                            Text(
                              '${formatJsonValue(slices[i].value, format)} '
                              '(${formatJsonValue(slices[i].value / total, JsonColumnFormat.percent)})',
                              style: theme.subtleTextStyle,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.values,
    required this.colors,
    required this.background,
  });

  final List<double> values;
  final List<Color> colors;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.shortestSide * 0.22;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - strokeWidth) / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = background);
    final total = values.fold<double>(0, (sum, v) => sum + v);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 2 * math.pi;
      canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) ||
      !listEquals(colors, oldDelegate.colors) ||
      background != oldDelegate.background;
}

/// Creates the `Stat` catalog item: a big formatted number with a label and
/// an optional sparkline.
CatalogItem statCatalogItem() => CatalogItem(
  name: 'Stat',
  dataSchema: S.object(
    description:
        'A single headline number (e.g. CPU %, heap used, request count) '
        'with a label, optional caption, threshold colors, and an optional '
        'sparkline of recent values. Put several in a Row for a dashboard.',
    properties: {
      'label': S.string(),
      'value': S.combined(
        description:
            'A data binding (e.g. {"path": "/summary/used"}) or a literal.',
        anyOf: [A2uiSchemas.dataBindingSchema(), S.number(), S.string()],
      ),
      'format': _formatSchema,
      'caption': S.string(description: 'Optional small text under the value.'),
      'warnAbove': S.number(
        description: 'Show the value in a warning color above this.',
      ),
      'errorAbove': S.number(
        description: 'Show the value in an error color above this.',
      ),
      'history': _dataSchema(
        'Optional binding to a list of numbers, or rows with `historyField`, '
        'drawn as a sparkline (oldest first).',
      ),
      'historyField': S.string(
        description: 'Numeric field of `history` rows to plot.',
      ),
    },
    required: ['label', 'value'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Row",
          "children": ["heapSource", "heapStat"]
        },
        {
          "id": "heapSource",
          "component": "DataSource",
          "source": "memory.heapSamples",
          "expression": "{used: [-1].used, history: [-60:].used}",
          "targetPath": "/heap"
        },
        {
          "id": "heapStat",
          "component": "Stat",
          "label": "Dart heap used",
          "value": {"path": "/heap/used"},
          "format": "bytes",
          "history": {"path": "/heap/history"}
        }
      ]
    ''',
  ],
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final data = itemContext.data as JsonObject;
    return BoundedWidth(
      width: 200,
      child: ResolvedValueBuilder(
        dataContext: itemContext.dataContext,
        value: data['value'],
        builder: (context, value) => ResolvedValueBuilder(
          dataContext: itemContext.dataContext,
          value: data['history'],
          builder: (context, history) => StatCard(
            label: data['label'] as String? ?? '',
            value: value,
            format: _formatOf(data),
            caption: data['caption'] as String?,
            warnAbove: (data['warnAbove'] as num?)?.toDouble(),
            errorAbove: (data['errorAbove'] as num?)?.toDouble(),
            history: numericSeries(
              history,
              field: data['historyField'] as String?,
            ),
          ),
        ),
      ),
    );
  },
);

/// A headline number with a label and optional sparkline.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.format = JsonColumnFormat.number,
    this.caption,
    this.warnAbove,
    this.errorAbove,
    this.history = const [],
  });

  final String label;
  final Object? value;
  final JsonColumnFormat format;
  final String? caption;
  final double? warnAbove;
  final double? errorAbove;
  final List<double> history;

  /// The color for [value] given the thresholds, or null for the default.
  @visibleForTesting
  static Color? thresholdColor(
    Object? value, {
    double? warnAbove,
    double? errorAbove,
    required ColorScheme colorScheme,
  }) {
    if (value is! num) return null;
    if (errorAbove != null && value > errorAbove) return colorScheme.error;
    if (warnAbove != null && value > warnAbove) return Colors.orange;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueColor = thresholdColor(
      value,
      warnAbove: warnAbove,
      errorAbove: errorAbove,
      colorScheme: theme.colorScheme,
    );
    final formatted = value == null ? '–' : formatJsonValue(value, format);
    return RoundedOutlinedBorder(
      child: Padding(
        padding: const EdgeInsets.all(denseSpacing),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.subtleTextStyle,
            ),
            Text(
              formatted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(color: valueColor),
            ),
            if (caption != null)
              Text(
                caption!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.subtleTextStyle,
              ),
            if (history.length > 1) ...[
              const SizedBox(height: densePadding),
              SizedBox(
                height: 28,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    values: history,
                    color: valueColor ?? genUiChartPalette.first,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final range = maxValue - minValue;
    Offset point(int i) => Offset(
      i / (values.length - 1) * size.width,
      range == 0
          ? size.height / 2
          : size.height - (values[i] - minValue) / range * size.height,
    );
    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(point(i).dx, point(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(fill, Paint()..color = color.withValues(alpha: 0.2))
      ..drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) || color != oldDelegate.color;
}
