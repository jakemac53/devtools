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

A wrong prefix fails with an error whose text varies (e.g. `Unknown method`,
`Method not found`, or an internal "Null check operator used on a null value"
error). Treat any error as "wrong prefix": try `s2.genUi`, `s3.genUi`, ... one
at a time (up to about `s10`), and use whichever works for the rest of the
session. The prefix changes if DevTools reconnects or is reloaded, so probe
again if a working prefix starts failing.

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
   When DevTools is shown in the `devtools_genui` side pane, interactions also
   arrive as chat messages from the user; handle those directly.

Buttons bound to DevTools actions run in DevTools; mutating actions ask the
user for confirmation there. Never invent data source or action ids.

## Launching DevTools

If every prefix fails, no DevTools is connected to the app with GenUI enabled.
Open one yourself instead of asking the user to set it up:

<!-- TODO: The Dart SDK's DevTools does not include GenUI yet, so for this
prototype everyone uses one shared DevTools build from the GenUI branch,
hosted at http://jakemac0.c.googlers.com:8086. Once GenUI ships, go back to
starting a local one with `dart devtools --machine --no-launch-browser
--port=0 --dtd-uri=<DTD URI>` and reading `host` and `port` from its
`server.started` line. -->

1. Get the app's VM service URI from the Dart MCP server's `dtd` tool
   (`listDtdUris`, then `connect` and `listConnectedApps`).
2. Use the hosted GenUI DevTools at `http://jakemac0.c.googlers.com:8086`. Do
   not start a DevTools server. The page runs in the user's browser and
   connects to the app from there; the side pane routes that connection to
   this machine for you.
3. Build the URL, URL-encoding the VM service URI:

   ```text
   http://jakemac0.c.googlers.com:8086/genui?uri=<encoded VM service URI>&enableGenUi=true
   ```

   `enableGenUi=true` turns the GenUI experiment on for that session without
   changing the user's saved settings.
4. Show the URL to the user:
   - **In Antigravity or Jetski with the `devtools_genui` plugin enabled**,
     reply with a link that opens it in the side pane, URL-encoding the whole
     DevTools URL into the `url` parameter:

     ```markdown
     [Open DevTools GenUI](sidecar://devtools_genui/devtools/?url=<encoded DevTools URL>)
     ```

   - **Otherwise**, give the user the URL to open in their browser. This only
     works if their browser runs on the same machine as the app, since the
     VM service URI is a loopback address.
5. Once the page has loaded and connected (usually a few seconds), the side
   pane sends you a chat message saying DevTools GenUI is ready, with the
   exact method to call (e.g. `s2.genUi`); use it without probing. Without
   the side pane, probe the `sN.genUi` prefixes again, retrying for up to
   about 30 seconds.

Reuse the same DevTools page for the rest of the session.

## Troubleshooting

- **Every prefix fails**: DevTools is not connected to this app, or the GenUI
  experiment is off. Launch DevTools as described above. If the user already
  has DevTools open, they can instead enable **Settings (gear icon) >
  Experimental features > Enable GenUI** and reload the page.
- **"The GenUI experiment is disabled"**: open the DevTools URL with
  `enableGenUi=true`, or ask the user to enable it as above.
- **"DevTools is not connected to this app"**: open a DevTools URL with the
  app's `uri`, as described above.
- **`vm_service` is not connected to the app**: call it with
  `command: connect` and the app's VM service URI as `appUri` first.
