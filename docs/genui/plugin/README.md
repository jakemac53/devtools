# DevTools GenUI plugin for Antigravity

A prototype [Antigravity / Jetski plugin](http://goto.google.com/jetski-agent-plugins)
that lets the agent build DevTools GenUI views of your running Dart or Flutter
app and show them in the side pane, with only the agent chat open.

It bundles:

- `skills/using-devtools-genui`: tells the agent how to start DevTools, connect
  it to your app, and drive GenUI through the Dart MCP server's `vm_service`
  tool.
- `sidecars/devtools`: a small UI sidecar. Its page shows the DevTools URL the
  agent links to in an iframe, and sends your interactions with the GenUI
  page back to the agent as chat messages.

The plugin doesn't run DevTools or know about the GenUI catalog. The agent
starts DevTools (`dart devtools --machine ...`), and DevTools owns the
components, data sources and actions.

## How it works

1. The agent starts a DevTools server and builds a URL like
   `http://127.0.0.1:<port>/genui?uri=<VM service URI>&enableGenUi=true`.
2. It replies with a `sidecar://devtools_genui/devtools/?url=<encoded URL>`
   link. Clicking it opens the side pane, which shows that URL (adding
   `embedMode=one`). The pane only accepts `localhost` / `127.0.0.1` URLs.
3. DevTools registers its `genUi` VM service method, and the agent renders UI.
4. When you click something in the GenUI page that needs the agent, DevTools
   posts a `devtools.genui.event` message to the pane, which forwards it to
   the agent as a chat message.

The host serves the pane from a public gateway origin, and browsers block
public pages from reaching loopback addresses (Chrome's Local Network
Access). So the sidecar backend proxies loopback servers under
`/proxy/<port>/` (HTTP and WebSockets), and the pane loads DevTools, and points
DevTools' VM service connection, through that same-origin proxy.

The backend has no dependencies (it doesn't use the host's `sidecar_sdk`), and
starts with the system `node` via `sh`, because some host builds don't ship
the bundled Node runtime.

## Install

Requires the Dart MCP server (e.g. from the Flutter plugin) and Node.js.

```sh
./install.sh
```

Then enable `devtools_genui` under **UI Plugins**.

> [!NOTE]
> Until GenUI ships in the Dart SDK's DevTools, `dart devtools` serves a
> DevTools without it. To try this, serve a DevTools build from the GenUI
> branch instead.
