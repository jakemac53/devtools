# DevTools GenUI plugin for Jetski

**Status: prototype.** Questions and feedback: jakemac@.

DevTools GenUI lets the Jetski agent build custom, interactive Flutter DevTools
views of your running Dart or Flutter app (memory, CPU, widget tree, network,
...), bound to live data. The views appear in Jetski's side pane. When you
click something that needs the agent, the click is sent to the agent as a chat
message.

## Prerequisites

- **Jetski** (Antigravity for Googlers).
- **The Dart MCP server.** The easiest way to get it is the **Flutter** plugin
  from the Agent Marketplace. Check that your agent has the `dart-mcp-server`
  tools (`vm_service`, `dtd`, ...).
- **Node.js** on your `PATH`, which runs the side pane's small local server.
  On gLinux: `sudo apt install nodejs`.
- **Access to `jakemac0.c.googlers.com:8086`** through ÜberProxy (any
  corp-managed browser). For now everyone shares one DevTools build from the
  GenUI branch, hosted there, because GenUI isn't in the Dart SDK yet.

## Install

```sh
/google/src/files/head/depot/google3/experimental/users/jakemac/devtools_genui/install.sh
```

This symlinks `~/.gemini/config/plugins/devtools_genui` to the plugin at google3
head, so you get updates automatically. Then make sure the `devtools_genui`
plugin is enabled in Jetski (run `/plugin` in a chat, or open the plugin
settings).

To uninstall, run the same script with `--uninstall`.

## Use it

1. Run your Dart or Flutter app in debug mode in a way the Dart MCP server can
   see, e.g. ask the agent to launch it, or run it from your IDE.
2. Ask the agent for a view, for example:
   - "Build me a dashboard of my app's memory usage"
   - "Show the widget tree next to the layout explorer"
   - "Which functions are using the most CPU right now?"
3. The agent replies with an **Open DevTools GenUI** link. Click it to open
   DevTools in the side pane. After a few seconds the pane tells the agent
   DevTools is ready, and the agent renders the view.
4. Keep chatting to refine the view, or click things in it.

## How it works

- `skills/using-devtools-genui` tells the agent how to open the hosted
  DevTools for your app and drive GenUI through the Dart MCP server's
  `vm_service` tool, by calling the `genUi` VM service method that DevTools
  registers on your app.
- `sidecars/devtools` is the side pane. It's a dependency-free Node server
  (`main.mjs`) and page (`index.html`, `shell.js`) that:
  - Shows DevTools in an iframe.
  - Proxies DevTools' connection to your app's VM service, which listens on
    loopback on your machine, under `/proxy/<port>/`. Browsers block the
    pane's page from reaching loopback addresses directly, and the VM service
    rejects connections from other origins.
  - Forwards DevTools' "ready" and user event messages to the agent as chat
    messages.

## Troubleshooting

- **The pane doesn't open, or is blank**: check that `node --version` works
  and look at
  `~/.gemini/jetski/sidecar_data/devtools_genui/devtools/logs/sidecar.log`.
  Toggling the plugin off and on restarts the pane's server.
- **DevTools loads but never connects**: make sure the app is still running.
  The agent can reopen DevTools for the app's current VM service URI.
- **Clicks go to a different agent**: if you set a Gemini API key in the
  DevTools GenUI page, its built-in agent receives the clicks instead of
  Jetski. Remove the key in the DevTools GenUI settings.

## Source

The plugin is developed in the
[`investigate_genui_devtools_integration`](https://github.com/jakemac53/devtools/tree/investigate_genui_devtools_integration)
branch of DevTools, under `docs/genui/plugin/`, and copied to
`google3/experimental/users/jakemac/devtools_genui/` for installing. Make
changes in DevTools, then copy the whole directory over.

To try local changes, run `install.sh --local` from your copy to link to it
instead of google3 head.
