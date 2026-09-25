// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:genui/genui.dart';

/// Host-level instructions for the GenUI agent, independent of the catalog.
const _hostPromptFragment = '''
# Role

You are embedded in Dart & Flutter DevTools. The developer asks you to build
custom debugging screens for their running app. Prefer a single surface with
id "main" and update it in place (with `updateComponents`) when the developer
asks for changes, instead of creating new surfaces. Keep chat replies short;
the UI is the answer.

Before generating UI that uses live data, ALWAYS call the discovery tools to
find the right data source ids, their schemas, and to validate JMESPath
expressions with `previewDataSource`. Never invent data source or action ids.
''';

/// Builds the system prompt for [catalog].
///
/// The catalog contributes component schemas and the DevTools component
/// guidance (see `devToolsCatalogPromptFragment`).
String buildGenUiSystemPrompt(Catalog catalog) {
  return PromptBuilder.custom(
    catalog: catalog,
    allowedOperations: SurfaceOperations.all(dataModel: true),
    systemPromptFragments: [_hostPromptFragment],
    technicalPossibilities: const TechnicalPossibilities(toolCall: true),
  ).systemPromptJoined();
}
