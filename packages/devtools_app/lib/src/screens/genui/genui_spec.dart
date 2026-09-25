// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:genui/genui.dart';

import 'data/json_utils.dart';

/// The version of the saved GenUI spec format.
const genUiSpecVersion = 1;

/// Serializes surfaces into a replayable spec.
///
/// A spec is a list of plain A2UI messages (`createSurface` +
/// `updateComponents` per surface). Because all live data is bound through
/// `DataSource` components, a spec contains no data and can be replayed
/// later - or shared - without the LLM.
JsonObject surfacesToSpec(Iterable<SurfaceDefinition> definitions) {
  return {
    'genUiSpecVersion': genUiSpecVersion,
    'messages': [
      for (final definition in definitions) ...[
        core.CreateSurfaceMessage(
          surfaceId: definition.surfaceId,
          catalogId: definition.catalogId,
        ).toJson(),
        core.UpdateComponentsMessage(
          surfaceId: definition.surfaceId,
          components: [
            for (final component in definition.components.values)
              component.toJson(),
          ],
        ).toJson(),
      ],
    ],
  };
}

/// Parses a spec produced by [surfacesToSpec] (or a bare JSON list of A2UI
/// messages) into A2UI messages.
///
/// Throws a [FormatException] if [source] is not a valid spec.
List<core.A2uiMessage> parseSpec(String source) {
  final Object? decoded = jsonDecode(source);
  final Object? messages = switch (decoded) {
    {'messages': final Object? m} => m,
    List() => decoded,
    _ => null,
  };
  if (messages is! List) {
    throw const FormatException('Expected a list of A2UI messages.');
  }
  return [
    for (final message in messages)
      if (message is Map)
        core.A2uiMessage.fromJson(message.cast<String, dynamic>())
      else
        throw FormatException('Invalid A2UI message: $message'),
  ];
}
