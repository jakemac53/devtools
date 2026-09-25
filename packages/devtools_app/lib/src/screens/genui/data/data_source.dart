// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jmespath/jmespath.dart' as jmespath;
import 'package:json_schema_builder/json_schema_builder.dart';

import 'json_utils.dart';
import 'ref_store.dart';

/// Signature for opening a live data source.
///
/// Implementations should emit a new JSON-compatible value whenever the
/// underlying data changes. Values must only contain JSON primitives, lists,
/// and maps with string keys (see [toJsonSafe]).
typedef DataSourceOpener =
    Stream<Object?> Function(DataSourceContext context, JsonObject params);

/// Context passed to [DataSourceOpener]s and action runners.
class DataSourceContext {
  DataSourceContext({required this.refs});

  /// Used to hand out opaque `_ref` handles for typed DevTools objects so that
  /// generated UI can refer back to them (e.g. to open a details pane).
  final GenUiRefStore refs;
}

/// Describes a named, typed, live data source that generated UI can bind to.
///
/// Data sources are thin adapters over existing DevTools controllers and
/// services: they project typed Dart models into JSON rows so that the same
/// data powers both the regular DevTools screens and generated UI.
class DataSourceDescriptor {
  const DataSourceDescriptor({
    required this.id,
    required this.description,
    required this.paramsSchema,
    required this.outputSchema,
    required this.open,
    this.exampleExpressions = const [],
  });

  /// Stable, namespaced identifier, e.g. `network.httpRequests`.
  final String id;

  /// Human (and LLM) readable description of the data.
  final String description;

  /// JSON schema for the parameters accepted by [open].
  final Schema paramsSchema;

  /// JSON schema describing the shape of the emitted values.
  final Schema outputSchema;

  /// Example JMESPath expressions that are useful with this source.
  final List<String> exampleExpressions;

  /// Opens a live stream of values for this source.
  final DataSourceOpener open;

  /// A short summary used when listing sources.
  JsonObject toSummaryJson() => {'id': id, 'description': description};

  /// The full description used when an agent asks about this source.
  JsonObject toDescriptionJson() => {
    'id': id,
    'description': description,
    'paramsSchema': paramsSchema.value,
    'outputSchema': outputSchema.value,
    if (exampleExpressions.isNotEmpty) 'exampleExpressions': exampleExpressions,
  };
}

/// Thrown when a data source or action cannot be found or fails.
class GenUiDataException implements Exception {
  GenUiDataException(this.message);

  final String message;

  @override
  String toString() => 'GenUiDataException: $message';
}

/// The registry of [DataSourceDescriptor]s available to generated UI.
class DataSourceRegistry {
  DataSourceRegistry({GenUiRefStore? refs}) : refs = refs ?? GenUiRefStore();

  final GenUiRefStore refs;

  final _sources = <String, DataSourceDescriptor>{};

  /// Registers [descriptor], replacing any existing source with the same id.
  void register(DataSourceDescriptor descriptor) {
    _sources[descriptor.id] = descriptor;
  }

  /// Registers all of [descriptors].
  void registerAll(Iterable<DataSourceDescriptor> descriptors) {
    descriptors.forEach(register);
  }

  /// All registered sources, sorted by id.
  List<DataSourceDescriptor> get sources =>
      _sources.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  DataSourceDescriptor? lookup(String id) => _sources[id];

  /// Opens [sourceId] with [params], optionally transforming each emitted
  /// value with the JMESPath [expression].
  ///
  /// The returned stream is a broadcast stream that stops listening to the
  /// underlying source when all listeners cancel.
  Stream<Object?> query(
    String sourceId, {
    JsonObject params = const {},
    String? expression,
  }) {
    final source = lookup(sourceId);
    if (source == null) {
      return Stream.error(GenUiDataException('Unknown data source: $sourceId'));
    }
    final jmespath.JmesPathExpression? compiled;
    final Stream<Object?> raw;
    try {
      compiled = _compile(expression);
      raw = source.open(DataSourceContext(refs: refs), params);
    } catch (e, st) {
      return Stream.error(e, st);
    }
    if (compiled == null) return raw;
    return raw.map(compiled.search);
  }

  /// Returns a single, truncated sample of [sourceId] suitable for showing to
  /// an agent, so that it can validate [expression] before generating UI.
  Future<Object?> preview(
    String sourceId, {
    JsonObject params = const {},
    String? expression,
    int limit = 5,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final value = await query(
      sourceId,
      params: params,
      expression: expression,
    ).first.timeout(timeout);
    return truncateForPreview(value, maxListLength: limit);
  }

  jmespath.JmesPathExpression? _compile(String? expression) {
    if (expression == null || expression.trim().isEmpty) return null;
    try {
      return jmespath.compile(expression);
    } on jmespath.JmesPathException catch (e) {
      throw GenUiDataException('Invalid JMESPath expression "$expression": $e');
    }
  }
}

/// Converts a [ValueListenable] into a stream of projected JSON values.
///
/// Emits the current value immediately, then emits again whenever
/// [listenable] notifies, throttled to at most one emission per [throttle].
Stream<Object?> streamFromListenable<T>(
  ValueListenable<T> listenable,
  Object? Function(T value) project, {
  Duration throttle = const Duration(milliseconds: 250),
}) {
  return streamFromListenables(
    [listenable],
    () => project(listenable.value),
    throttle: throttle,
  );
}

/// Like [streamFromListenable], but re-projects whenever any of [listenables]
/// notifies.
Stream<Object?> streamFromListenables(
  List<Listenable> listenables,
  Object? Function() project, {
  Duration throttle = const Duration(milliseconds: 250),
}) {
  late StreamController<Object?> controller;
  Timer? pending;
  var dirty = false;
  final merged = Listenable.merge(listenables);

  void emit() {
    if (controller.isClosed) return;
    try {
      controller.add(project());
    } catch (e, st) {
      controller.addError(e, st);
    }
  }

  void onChange() {
    if (pending != null) {
      dirty = true;
      return;
    }
    emit();
    pending = Timer(throttle, () {
      pending = null;
      if (dirty) {
        dirty = false;
        onChange();
      }
    });
  }

  controller = StreamController<Object?>(
    onListen: () {
      merged.addListener(onChange);
      emit();
    },
    onCancel: () {
      merged.removeListener(onChange);
      pending?.cancel();
    },
  );
  return controller.stream;
}
