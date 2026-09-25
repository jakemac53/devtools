// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../data/data_source.dart';
import 'bound_value.dart';

/// The name of the non-visual component that binds a DevTools data source
/// into the surface's data model.
const dataSourceComponentName = 'DataSource';

/// Creates the `DataSource` catalog item.
///
/// This is the bridge between live DevTools data and A2UI's data model: it
/// opens [registry] source `source` with `params`, applies the optional
/// JMESPath `expression`, and writes every result to `targetPath`. Visual
/// components then bind to `targetPath` with regular A2UI data bindings.
///
/// Params may themselves be bindings (e.g. `{"path": "/selectedIsolate/id"}`)
/// which enables master/detail UIs: when the bound value changes, the source
/// is re-opened.
CatalogItem dataSourceCatalogItem(DataSourceRegistry registry) => CatalogItem(
  name: dataSourceComponentName,
  dataSchema: S.object(
    description:
        'Non-visual. Streams a live DevTools data source into the data model '
        'at `targetPath`. Place it anywhere in the tree (e.g. as a child of '
        'the root Column); it renders nothing unless there is an error. Use '
        'listDataSources / describeDataSource / previewDataSource to discover '
        'sources.',
    properties: {
      'source': S.string(description: 'The data source id.'),
      'params': S.object(
        description:
            'Parameters for the source. Each value may be a literal or a '
            'data binding like {"path": "/selected/id"}.',
        additionalProperties: true,
      ),
      'expression': S.string(
        description:
            'Optional JMESPath expression applied to every emitted value, '
            'e.g. "[?status != \'200\'].{uri: uri, ms: durationMs}".',
      ),
      'targetPath': S.string(
        description: 'Absolute data model path to write results to.',
      ),
      'errorPath': S.string(
        description:
            'Optional data model path that receives an error message (or '
            'null when healthy).',
      ),
    },
    required: ['source', 'targetPath'],
  ),
  exampleData: [
    () => '''
      [
        {
          "id": "root",
          "component": "Column",
          "children": ["requestsSource", "requestsTable"]
        },
        {
          "id": "requestsSource",
          "component": "DataSource",
          "source": "network.requests",
          "expression": "[?method == 'GET']",
          "targetPath": "/requests"
        },
        {
          "id": "requestsTable",
          "component": "JsonTable",
          "rows": {"path": "/requests"},
          "preset": "network.requests",
          "selectionPath": "/selectedRequest"
        }
      ]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    return DataSourceBinding(
      key: ValueKey('${itemContext.surfaceId}/${itemContext.id}'),
      registry: registry,
      dataContext: itemContext.dataContext,
      config: DataSourceConfig.fromJson(data),
      onError: (error, stackTrace) => itemContext.reportError(
        // genui only forwards the message of A2UI exceptions to the agent.
        A2uiValidationException(
          error.toString(),
          surfaceId: itemContext.surfaceId,
          path: itemContext.id,
        ),
        stackTrace,
      ),
    );
  },
);

/// The parsed properties of a `DataSource` component.
class DataSourceConfig {
  const DataSourceConfig({
    required this.source,
    required this.targetPath,
    this.params = const {},
    this.expression,
    this.errorPath,
  });

  factory DataSourceConfig.fromJson(Map<String, Object?> json) {
    final params = json['params'];
    return DataSourceConfig(
      source: json['source'] as String? ?? '',
      targetPath: json['targetPath'] as String? ?? '',
      params: params is Map ? params.cast<String, Object?>() : const {},
      expression: json['expression'] as String?,
      errorPath: json['errorPath'] as String?,
    );
  }

  final String source;
  final Map<String, Object?> params;
  final String? expression;
  final String targetPath;
  final String? errorPath;

  bool sameAs(DataSourceConfig other) =>
      source == other.source &&
      expression == other.expression &&
      targetPath == other.targetPath &&
      errorPath == other.errorPath &&
      jsonEquals(params, other.params);
}

/// Keeps a DevTools data source bound to a data model path while mounted.
@visibleForTesting
class DataSourceBinding extends StatefulWidget {
  const DataSourceBinding({
    super.key,
    required this.registry,
    required this.dataContext,
    required this.config,
    this.onError,
  });

  final DataSourceRegistry registry;
  final DataContext dataContext;
  final DataSourceConfig config;
  final void Function(Object error, StackTrace stackTrace)? onError;

  @override
  State<DataSourceBinding> createState() => _DataSourceBindingState();
}

class _DataSourceBindingState extends State<DataSourceBinding> {
  final _paramSubscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<Object?>? _sourceSubscription;
  Map<String, Object?> _resolvedParams = {};
  Map<String, Object?>? _lastQueriedParams;
  final _reportedErrors = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(DataSourceBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.config.sameAs(widget.config) ||
        !identical(oldWidget.registry, widget.registry) ||
        !identical(oldWidget.dataContext, widget.dataContext)) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _bind() {
    final params = widget.config.params;
    _resolvedParams = {
      for (final entry in params.entries)
        if (!isBinding(entry.value)) entry.key: entry.value,
    };
    final pending = {
      for (final entry in params.entries)
        if (isBinding(entry.value)) entry.key,
    };
    for (final entry in params.entries) {
      if (!isBinding(entry.value)) continue;
      _paramSubscriptions.add(
        widget.dataContext.resolve(entry.value).listen((value) {
          pending.remove(entry.key);
          _resolvedParams = {..._resolvedParams, entry.key: value};
          if (pending.isEmpty) _query();
        }),
      );
    }
    // Defer so that data model updates never happen during a build.
    if (pending.isEmpty) scheduleMicrotask(_query);
  }

  void _unbind() {
    for (final s in _paramSubscriptions) {
      unawaited(s.cancel());
    }
    _paramSubscriptions.clear();
    unawaited(_sourceSubscription?.cancel());
    _sourceSubscription = null;
    _lastQueriedParams = null;
  }

  void _query() {
    if (!mounted) return;
    if (_lastQueriedParams != null &&
        jsonEquals(_lastQueriedParams, _resolvedParams)) {
      return;
    }
    _lastQueriedParams = _resolvedParams;
    unawaited(_sourceSubscription?.cancel());
    final config = widget.config;
    if (config.targetPath.isEmpty) {
      _setError('DataSource "${config.source}" is missing a targetPath.');
      return;
    }
    try {
      _sourceSubscription = widget.registry
          .query(
            config.source,
            params: _resolvedParams,
            expression: config.expression,
          )
          .listen((value) {
            widget.dataContext.update(DataPath(config.targetPath), value);
            _setError(null);
          }, onError: (Object e, StackTrace st) => _setError(e.toString(), st));
    } catch (e, st) {
      _setError(e.toString(), st);
    }
  }

  void _setError(String? message, [StackTrace? stackTrace]) {
    if (message == _error) return;
    final errorPath = widget.config.errorPath;
    if (errorPath != null && errorPath.isNotEmpty) {
      widget.dataContext.update(DataPath(errorPath), message);
    }
    if (message != null && _reportedErrors.add(message)) {
      widget.onError?.call(
        GenUiDataException(
          'DataSource "${widget.config.source}" failed: $message',
        ),
        stackTrace ?? StackTrace.current,
      );
    }
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Text(
        'Data source "${widget.config.source}" error: $error',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
