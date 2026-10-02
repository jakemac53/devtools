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
`listRegisteredServices` command instead of guessing the `sN.` prefix. -->

Services registered by VM service clients are called with a client prefix,
`sN.`, where `N` is the ID the VM service gave DevTools' connection. IDs are
assigned in connection order (including IDEs, DDS, other tools and earlier
DevTools sessions), so the number varies. Call the `vm_service` tool with
`command: callMethod`, `method: s1.genUi` and the command in `arguments`:

```json
{"command": "callMethod", "method": "s1.genUi", "arguments": {"command": "help"}}
```

A wrong prefix fails with an internal error such as "Null check operator used
on a null value" (from `NamedLookup`) or "Method not found". Try `s2.genUi`,
`s3.genUi`, ... one at a time (up to about `s10`), and use whichever works for
the rest of the session. The prefix changes if DevTools reconnects or is
reloaded, so probe again if a working prefix starts failing.

Pass a command's params as top-level keys of `arguments`, next to `command`,
not nested under `params`:

```json
{"command": "callMethod", "method": "s2.genUi",
 "arguments": {"command": "queryDataSource", "id": "memory.classes",
               "expression": "[:10].{class: class, bytes: totalBytes}"}}
```

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

- **Every prefix fails**: DevTools is not connected to this app, or the GenUI
  experiment is off. Ask the user to open DevTools for the app (e.g. from
  their IDE, or by pasting the app's VM service URI into DevTools' connect
  dialog), then enable **Settings (gear icon) > Experimental features >
  Enable GenUI**, and reload the DevTools page if it still fails. Then probe
  the prefixes again.
- **"The GenUI experiment is disabled"**: ask the user to enable it as above.
- **"DevTools is not connected to this app"**: ask the user to connect
  DevTools to the app.
- **`vm_service` is not connected to the app**: call it with
  `command: connect` and the app's VM service URI as `appUri` first.
