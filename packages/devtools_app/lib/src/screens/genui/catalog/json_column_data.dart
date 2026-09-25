// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import '../../../shared/primitives/byte_utils.dart';
import '../../../shared/primitives/utils.dart';
import '../../../shared/table/table_data.dart';
import '../data/json_utils.dart';

/// How a [JsonColumnData] formats its values.
///
/// Each format reuses the formatter that the regular DevTools screens use, so
/// generated tables look the same as hand-written ones.
enum JsonColumnFormat {
  /// Plain `toString()`.
  string,

  /// A number, right-aligned. Doubles are shown with up to 2 fraction digits.
  number,

  /// A byte count, e.g. `1.2 MB`.
  bytes,

  /// A duration given in milliseconds, e.g. `12.3 ms`.
  duration,

  /// A timestamp given in milliseconds since epoch, shown as `HH:mm:ss`.
  timestamp,

  /// A ratio in [0, 1], shown as a percentage.
  percent,

  /// A boolean, shown as a check mark.
  boolean;

  static JsonColumnFormat parse(Object? value) {
    if (value is String) {
      for (final format in values) {
        if (format.name == value) return format;
      }
    }
    return string;
  }

  bool get isNumeric => switch (this) {
    number || bytes || duration || timestamp || percent => true,
    string || boolean => false,
  };
}

/// Formats [value] according to [format].
String formatJsonValue(Object? value, JsonColumnFormat format) {
  if (value == null) return '';
  switch (format) {
    case JsonColumnFormat.bytes:
      return value is num
          ? prettyPrintBytes(value, includeUnit: true) ?? ''
          : value.toString();
    case JsonColumnFormat.duration:
      return value is num
          ? durationText(Duration(microseconds: (value * 1000).round()))
          : value.toString();
    case JsonColumnFormat.timestamp:
      return value is num ? prettyTimestamp(value.toInt()) : value.toString();
    case JsonColumnFormat.percent:
      return value is num ? percent(value.toDouble()) : value.toString();
    case JsonColumnFormat.number:
      if (value is double) {
        return value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toStringAsFixed(2);
      }
      return value.toString();
    case JsonColumnFormat.boolean:
      return value == true ? '✓' : '';
    case JsonColumnFormat.string:
      return value is Map || value is List
          ? jsonEncode(toJsonSafe(value))
          : '$value';
  }
}

/// A generic [ColumnData] that reads a (dotted) field from a JSON row.
///
/// This lets generated UI reuse DevTools' `FlatTable` for any data source
/// without writing a typed column class per model.
class JsonColumnData extends ColumnData<JsonObject> {
  JsonColumnData({
    required String title,
    required this.field,
    this.format = JsonColumnFormat.string,
    double? widthPx,
  }) : _path = field.split('.'),
       super(
         title,
         fixedWidthPx: widthPx ?? _defaultWidth(format),
         alignment: format.isNumeric
             ? ColumnAlignment.right
             : ColumnAlignment.left,
         showTooltip: true,
       );

  JsonColumnData.wide({
    required String title,
    required this.field,
    this.format = JsonColumnFormat.string,
    double? minWidthPx,
  }) : _path = field.split('.'),
       super.wide(
         title,
         minWidthPx: minWidthPx,
         alignment: format.isNumeric
             ? ColumnAlignment.right
             : ColumnAlignment.left,
         showTooltip: true,
       );

  /// Parses a column spec of the form
  /// `{field, title?, format?, width?, wide?}`.
  factory JsonColumnData.fromJson(JsonObject json) {
    final field = json['field'];
    if (field is! String || field.isEmpty) {
      throw FormatException('Column is missing a `field`: $json');
    }
    final title = json['title'] as String? ?? field;
    final format = JsonColumnFormat.parse(json['format']);
    final width = (json['width'] as num?)?.toDouble();
    if (json['wide'] == true) {
      return JsonColumnData.wide(
        title: title,
        field: field,
        format: format,
        minWidthPx: width,
      );
    }
    return JsonColumnData(
      title: title,
      field: field,
      format: format,
      widthPx: width,
    );
  }

  static double _defaultWidth(JsonColumnFormat format) => switch (format) {
    JsonColumnFormat.boolean => 60,
    JsonColumnFormat.timestamp => 90,
    JsonColumnFormat.string => 160,
    _ => 100,
  };

  /// The field to read. Dots traverse nested maps, e.g. `request.uri`.
  final String field;

  final JsonColumnFormat format;

  final List<String> _path;

  @override
  bool get numeric => format.isNumeric;

  @override
  Object? getValue(JsonObject dataObject) {
    Object? current = dataObject;
    for (final segment in _path) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return current;
  }

  @override
  String getDisplayValue(JsonObject dataObject) =>
      formatJsonValue(getValue(dataObject), format);

  @override
  int compare(JsonObject a, JsonObject b) {
    final valueA = getValue(a);
    final valueB = getValue(b);
    if (valueA is bool && valueB is bool) {
      return (valueA ? 1 : 0).compareTo(valueB ? 1 : 0);
    }
    return super.compare(a, b);
  }
}

/// Named column presets, so that the agent does not have to spell out
/// columns for well known data sources.
final jsonColumnPresets = <String, List<JsonObject>>{
  'network.requests': [
    {'field': 'method', 'title': 'Method', 'width': 70},
    {'field': 'uri', 'title': 'Uri', 'wide': true},
    {'field': 'status', 'title': 'Status', 'width': 70},
    {'field': 'type', 'title': 'Type', 'width': 70},
    {
      'field': 'durationMs',
      'title': 'Duration',
      'format': 'duration',
      'width': 90,
    },
    {'field': 'startTime', 'title': 'Timestamp', 'format': 'timestamp'},
  ],
  'vm.isolates': [
    {'field': 'name', 'title': 'Name', 'wide': true},
    {'field': 'id', 'title': 'Id', 'width': 180},
    {'field': 'isSystemIsolate', 'title': 'System', 'format': 'boolean'},
    {'field': 'selected', 'title': 'Selected', 'format': 'boolean'},
  ],
  'memory.heapSamples': [
    {'field': 'timestamp', 'title': 'Time', 'format': 'timestamp'},
    {'field': 'used', 'title': 'Dart heap used', 'format': 'bytes'},
    {'field': 'capacity', 'title': 'Dart heap capacity', 'format': 'bytes'},
    {'field': 'external', 'title': 'External', 'format': 'bytes'},
    {'field': 'rss', 'title': 'RSS', 'format': 'bytes'},
  ],
  'memory.classes': [
    {'field': 'class', 'title': 'Class', 'wide': true},
    {'field': 'library', 'title': 'Library', 'wide': true},
    {'field': 'classType', 'title': 'Type', 'width': 90},
    {'field': 'instances', 'title': 'Instances', 'format': 'number'},
    {'field': 'totalBytes', 'title': 'Total size', 'format': 'bytes'},
    {'field': 'dartHeapBytes', 'title': 'Dart heap', 'format': 'bytes'},
    {'field': 'externalBytes', 'title': 'External', 'format': 'bytes'},
  ],
};
