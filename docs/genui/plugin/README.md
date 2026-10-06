# DevTools GenUI plugin for Antigravity

A prototype [Antigravity](https://antigravity.google) plugin that lets the
agent build DevTools GenUI views of your running Dart or Flutter app and show
them in the side pane, with only the agent chat open.

It bundles:

- `skills/using-devtools-genui`: tells the agent how to open DevTools for your
  app and drive GenUI through the Dart MCP server's `vm_service` tool.
- `sidecars/devtools`: a small UI sidecar. Its page shows the DevTools URL the
  agent links to in an iframe, and sends DevTools' "ready" message and your
  interactions with the GenUI page back to the agent as chat messages.

The plugin doesn't know about the GenUI catalog; DevTools owns the
components, data sources and actions.

## How it works

1. The agent gets your app's VM service URI and builds a DevTools URL like
   `<DevTools>/genui?uri=<VM service URI>&enableGenUi=true`.
2. It replies with a `sidecar://devtools_genui/devtools/?url=<encoded URL>`
   link. Clicking it opens the side pane, which shows that URL (adding
   `embedMode=one`). The pane accepts loopback DevTools URLs and an allowlist
   of hosted DevTools servers (`hostedDevToolsHosts` in `shell.js`).
3. DevTools registers its `genUi` VM service method on the app and posts a
   `devtools.genui.ready` message with the method name. The pane tells the
   agent, which then renders UI.
4. When you click something in the GenUI page that needs the agent, DevTools
   posts a `devtools.genui.event` message to the pane, which forwards it to
   the agent as a chat message.

The host serves the pane from a gateway origin, and browsers block such pages
from reaching loopback addresses (Chrome's Local Network Access), while the
VM service rejects WebSockets from other origins. So the sidecar backend
proxies loopback servers under `/proxy/<port>/` (HTTP and WebSockets,
rewriting `Origin`), and the pane points DevTools' VM service connection
through that same-origin proxy.

The backend has no dependencies (it doesn't use the host's `sidecar_sdk`), and
starts with the system `node` via `sh`, because some host builds don't ship
the bundled Node runtime.

## Install

Requires the Dart MCP server (e.g. from the Flutter plugin) and Node.js.

```sh
./install.sh
```

This symlinks this directory into `~/.gemini/config/plugins/`. Then enable the
`devtools_genui` plugin.

> [!NOTE]
> Until GenUI ships in the Dart SDK's DevTools, `dart devtools` serves a
> DevTools without it. To try this, serve a DevTools build from the GenUI
> branch (`dt serve`) and point the skill and `hostedDevToolsHosts` at it.
