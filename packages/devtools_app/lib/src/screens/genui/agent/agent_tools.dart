// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import '../data/json_utils.dart';
import '../sources/default_registries.dart';

/// Signature for a tool handler. Must return JSON-safe values.
typedef GenUiToolHandler = Future<Object?> Function(JsonObject input);

/// A transport-agnostic tool that an agent can call to discover what DevTools
/// can show.
///
/// These map 1:1 onto LLM function-calling tools (see `GenkitTransport`) and
/// onto MCP tools (for the future MCP App host), so the discovery surface is
/// defined exactly once.
class GenUiAgentTool {
  const GenUiAgentTool({
    required this.name,
    required this.description,
    required this.inputJsonSchema,
    required this.handler,
  });

  final String name;
  final String description;

  /// A JSON schema (as a plain map) for the tool input.
  final JsonObject inputJsonSchema;

  final GenUiToolHandler handler;

  /// Runs the tool, converting failures into an `{error: ...}` result so the
  /// agent can recover instead of aborting the turn.
  Future<Object?> call(JsonObject input) async {
    try {
      return toJsonSafe(await handler(input));
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}

/// Returns a JSON description of the current state of the surfaces, or null
/// if there are none.
typedef SurfaceStateProvider = Object? Function(String? surfaceId);

/// The default number of list items returned by the `queryDataSource` tool.
const defaultQueryLimit = 100;

/// The maximum number of list items the `queryDataSource` tool will return.
const maxQueryLimit = 500;

/// Builds the discovery tools for [registries].
List<GenUiAgentTool> buildGenUiAgentTools(
  GenUiRegistries registries, {
  SurfaceStateProvider? surfaceState,
}) {
  final dataSources = registries.dataSources;
  final actions = registries.actions;

  JsonObject idSchema(String what) => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'The $what id.'},
    },
    'required': ['id'],
  };

  String requireString(JsonObject input, String key) {
    final value = input[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('`$key` must be a non-empty string.');
    }
    return value;
  }

  return [
    GenUiAgentTool(
      name: 'listDataSources',
      description:
          'Lists the live DevTools data sources that can be bound to UI with '
          'the DataSource component.',
      inputJsonSchema: {'type': 'object', 'properties': <String, Object?>{}},
      handler: (_) async => [
        for (final s in dataSources.sources) s.toSummaryJson(),
      ],
    ),
    GenUiAgentTool(
      name: 'describeDataSource',
      description:
          'Returns the params schema, output schema and example JMESPath '
          'expressions for a data source.',
      inputJsonSchema: idSchema('data source'),
      handler: (input) async {
        final id = requireString(input, 'id');
        final source = dataSources.lookup(id);
        if (source == null) throw ArgumentError('Unknown data source: $id');
        return source.toDescriptionJson();
      },
    ),
    GenUiAgentTool(
      name: 'previewDataSource',
      description:
          'Returns one truncated sample of a data source, optionally '
          'transformed by a JMESPath expression. Use this to check that an '
          'expression produces the shape you expect before generating UI.',
      inputJsonSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'params': {'type': 'object'},
          'expression': {'type': 'string', 'description': 'JMESPath.'},
        },
        'required': ['id'],
      },
      handler: (input) async {
        final id = requireString(input, 'id');
        final params = input['params'];
        return {
          'value': await dataSources.preview(
            id,
            params: params is Map ? params.cast<String, Object?>() : const {},
            expression: input['expression'] as String?,
          ),
        };
      },
    ),
    GenUiAgentTool(
      name: 'queryDataSource',
      description:
          'Returns a snapshot of the current value of a data source, '
          'optionally transformed by a JMESPath expression. Use this to '
          'answer questions about the app directly (e.g. "which class uses '
          'the most memory?") without generating UI. Aggregate, filter, '
          'sort and slice in the expression (e.g. sum(), length(), max_by(), '
          'sort_by(...)[-10:]) to keep the result small.\n'
          'If the result is a list it is paginated: you get {items, offset, '
          'totalLength, nextOffset?}. To read the next page, repeat the same '
          'call with `offset` set to `nextOffset`. Every call re-queries the '
          'live data, so rows may shift between pages; sort in the '
          'expression for a stable order. Other results are returned as '
          '{value}.',
      inputJsonSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'params': {'type': 'object'},
          'expression': {'type': 'string', 'description': 'JMESPath.'},
          'offset': {
            'type': 'integer',
            'description':
                'Index of the first list item to return (default 0).',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Page size for list results (default $defaultQueryLimit, '
                'max $maxQueryLimit). Also limits nested lists.',
          },
        },
        'required': ['id'],
      },
      handler: (input) async {
        final id = requireString(input, 'id');
        final params = input['params'];
        final limitInput = input['limit'];
        final limit = limitInput is num
            ? limitInput.toInt().clamp(1, maxQueryLimit)
            : defaultQueryLimit;
        final offsetInput = input['offset'];
        final offset = offsetInput is num ? offsetInput.toInt() : 0;
        if (offset < 0) throw ArgumentError('`offset` must not be negative.');

        final value = await dataSources
            .query(
              id,
              params: params is Map ? params.cast<String, Object?>() : const {},
              expression: input['expression'] as String?,
            )
            .first
            .timeout(const Duration(seconds: 10));
        if (value is List) {
          final start = offset.clamp(0, value.length);
          final end = (start + limit).clamp(0, value.length);
          return {
            'items': [
              for (final item in value.sublist(start, end))
                truncateForPreview(item, maxListLength: limit, maxDepth: 16),
            ],
            'offset': offset,
            'totalLength': value.length,
            if (end < value.length) 'nextOffset': end,
          };
        }
        return {
          'value': truncateForPreview(
            value,
            maxListLength: limit,
            maxDepth: 16,
          ),
        };
      },
    ),
    GenUiAgentTool(
      name: 'listActions',
      description:
          'Lists the DevTools actions that buttons can trigger. Actions run '
          'directly in DevTools without contacting you.',
      inputJsonSchema: {'type': 'object', 'properties': <String, Object?>{}},
      handler: (_) async => [
        for (final a in actions.actions) a.toSummaryJson(),
      ],
    ),
    GenUiAgentTool(
      name: 'describeAction',
      description: 'Returns the args schema for an action.',
      inputJsonSchema: idSchema('action'),
      handler: (input) async {
        final id = requireString(input, 'id');
        final action = actions.lookup(id);
        if (action == null) throw ArgumentError('Unknown action: $id');
        return action.toDescriptionJson();
      },
    ),
    if (surfaceState != null)
      GenUiAgentTool(
        name: 'getSurfaceState',
        description:
            'Returns the components and (truncated) data model of the '
            'current surfaces, e.g. to see what the user selected before '
            'modifying the UI.',
        inputJsonSchema: {
          'type': 'object',
          'properties': {
            'surfaceId': {
              'type': 'string',
              'description': 'Optional; defaults to all surfaces.',
            },
          },
        },
        handler: (input) async => truncateForPreview(
          surfaceState(input['surfaceId'] as String?),
          maxListLength: 10,
          maxDepth: 12,
        ),
      ),
  ];
}
