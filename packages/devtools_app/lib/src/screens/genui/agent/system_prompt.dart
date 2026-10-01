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

/// Host-level instructions for an external agent (e.g. a coding agent in an
/// IDE) that drives GenUI through the `genUi` VM service method instead of
/// the chat embedded in DevTools.
const _externalHostPromptFragment = '''
# Role

You are driving the GenUI page of Dart & Flutter DevTools through the `genUi`
VM service method. The developer sees the UI you render in their DevTools
window, next to their running app.

# How to send UI

Instead of writing A2UI messages in your reply, call the `render` command with
a `messages` argument containing a JSON list of A2UI message objects. Do NOT
wrap them in markdown; ignore any instructions below about fencing JSON in
code blocks. `render` returns any validation errors: fix them and render again.

Prefer a single surface with id "main" and update it in place (with
`updateComponents`) when the developer asks for changes, instead of creating
new surfaces.

Before generating UI that uses live data, ALWAYS call the discovery commands
to find the right data source ids, their schemas, and to validate JMESPath
expressions with `previewDataSource`. Never invent data source or action ids.
To answer a question about the app, prefer `queryDataSource` over building UI.
''';

/// Builds the system prompt for [catalog].
///
/// The catalog contributes component schemas and the DevTools component
/// guidance (see `devToolsCatalogPromptFragment`).
///
/// When [external] is true, the host instructions target an agent outside of
/// DevTools that sends A2UI messages with the `render` command of the `genUi`
/// VM service method (see `GenUiVmServiceHandler`).
String buildGenUiSystemPrompt(Catalog catalog, {bool external = false}) {
  return PromptBuilder.custom(
    catalog: catalog,
    allowedOperations: SurfaceOperations.all(dataModel: true),
    systemPromptFragments: [
      external ? _externalHostPromptFragment : _hostPromptFragment,
    ],
    technicalPossibilities: const TechnicalPossibilities(toolCall: true),
  ).systemPromptJoined();
}
