---
name: using-devtools-genui
description: Shows custom, interactive debugging UI in Flutter DevTools and answers questions about a running Dart or Flutter app using live DevTools data (memory, CPU, widget tree, network...). Use when the user wants to visualize or inspect their running app's state, or build a custom DevTools view, and the Dart MCP server's `vm_service` tool is available.
---

# Using DevTools GenUI

DevTools registers a `genUi` VM service method on the app it is connected to
while its GenUI experiment is enabled. Call it with the Dart MCP server's
`vm_service` tool (`command: callMethod`). Every call takes a `command`
argument; other arguments depend on the command.

## Calling `genUi`

Do everything through the Dart MCP server's `vm_service` tool; do not write
scripts or open your own VM service connection.

<!-- TODO: Once dart_mcp_server 1.2.0 is released
(https://github.com/dart-lang/ai/pull/697), call `genUi` directly and use the
`listRegisteredServices` command instead of guessing the `s1.` prefix. -->

Services registered by VM service clients are called with a client prefix.
Call the `vm_service` tool with `command: callMethod`, `method: s1.genUi` and
the command in `arguments`:

```json
{"command": "callMethod", "method": "s1.genUi", "arguments": {"command": "help"}}
```

If that returns "Method not found", try `s0.genUi`, `s2.genUi`, `s3.genUi`, and
use whichever works for the rest of the session.

## Workflow

1. Call `help` to get the commands and their params.
2. Discover data with `listDataSources`, `describeDataSource` and
   `previewDataSource` (validates a JMESPath `expression`).
3. To answer a question, use `queryDataSource` with an `expression` that
   filters, sorts and aggregates, so results stay small. Page with `offset`.
4. To build UI, call `getInstructions` once (A2UI protocol + component
   catalog), then `render` with `messages`: a JSON list of A2UI messages.
   Fix any returned `errors` and render again. Update the "main" surface in
   place rather than creating new surfaces.
5. Use `getSurfaceState` to see what the user selected, and `pollEvents` to
   receive their interactions (e.g. button presses with `event` actions).

Buttons bound to DevTools actions run in DevTools; mutating actions ask the
user for confirmation there. Never invent data source or action ids.

## Troubleshooting

- **"Method not found" for every prefix**: DevTools is not connected to this
  app, or the
  GenUI experiment is off. Ask the user to open DevTools for the app (e.g.
  from their IDE, or by pasting the app's VM service URI into DevTools'
  connect dialog), then enable **Settings (gear icon) > Experimental features
  > Enable GenUI**. Then retry.
- **"The GenUI experiment is disabled"**: ask the user to enable it as above.
- **"DevTools is not connected to this app"**: ask the user to connect
  DevTools to the app.
- **`vm_service` is not connected to the app**: call it with
  `command: connect` and the app's VM service URI as `appUri` first.
