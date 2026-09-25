// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:json_schema_builder/json_schema_builder.dart';

import 'data_source.dart';
import 'json_utils.dart';
import 'ref_store.dart';

/// Signature for running a DevTools action.
typedef ActionRunner =
    Future<Object?> Function(DataSourceContext context, JsonObject args);

/// Describes a named, allowlisted action that generated UI can trigger (for
/// example from a button).
///
/// Actions wrap existing controller methods so that the behavior is shared
/// with the regular DevTools screens. They are executed client-side, without
/// a round trip to the agent.
class ActionDescriptor {
  const ActionDescriptor({
    required this.id,
    required this.description,
    required this.run,
    Schema? argsSchema,
    this.mutatesApp = false,
  }) : _argsSchema = argsSchema;

  /// Stable, namespaced identifier, e.g. `memory.gc`.
  final String id;

  /// Human (and LLM) readable description of the action.
  final String description;

  final Schema? _argsSchema;

  /// JSON schema for the arguments accepted by [run].
  Schema get argsSchema => _argsSchema ?? S.object(properties: {});

  /// Whether this action changes the state of the connected app (as opposed
  /// to only changing DevTools state). Such actions require user
  /// confirmation before they run.
  final bool mutatesApp;

  final ActionRunner run;

  JsonObject toSummaryJson() => {
    'id': id,
    'description': description,
    'mutatesApp': mutatesApp,
  };

  JsonObject toDescriptionJson() => {
    ...toSummaryJson(),
    'argsSchema': argsSchema.value,
  };
}

/// The registry of [ActionDescriptor]s available to generated UI.
class ActionRegistry {
  ActionRegistry({required this.refs});

  final GenUiRefStore refs;

  final _actions = <String, ActionDescriptor>{};

  void register(ActionDescriptor descriptor) {
    _actions[descriptor.id] = descriptor;
  }

  void registerAll(Iterable<ActionDescriptor> descriptors) {
    descriptors.forEach(register);
  }

  /// All registered actions, sorted by id.
  List<ActionDescriptor> get actions =>
      _actions.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  ActionDescriptor? lookup(String id) => _actions[id];

  /// Runs the action [id] with [args].
  Future<Object?> run(String id, {JsonObject args = const {}}) async {
    final action = lookup(id);
    if (action == null) throw GenUiDataException('Unknown action: $id');
    final result = await action.run(DataSourceContext(refs: refs), args);
    return toJsonSafe(result);
  }
}
