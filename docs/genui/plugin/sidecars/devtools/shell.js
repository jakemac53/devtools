// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

// Shell for the DevTools GenUI side pane.
//
// The agent opens this page with `?url=<DevTools URL>` (via a
// `sidecar://devtools_genui/devtools/?url=...` link). The page shows that
// DevTools URL in an iframe, and forwards the messages DevTools posts to it
// (see `embedder_messages.dart` in DevTools) to the agent: that GenUI is ready,
// and the user's GenUI interactions.

const readyMessageType = 'devtools.genui.ready';
const eventMessageType = 'devtools.genui.event';
const lastUrlKey = 'devtools_genui.lastUrl';

const frame = document.getElementById('devtools');
const empty = document.getElementById('empty');
const status = document.getElementById('status');

const loopbackHosts = ['localhost', '127.0.0.1', '[::1]'];

/**
 * Hosts serving a shared DevTools build that the pane may show, besides
 * DevTools servers on this machine.
 *
 * TODO: The Dart SDK's DevTools does not include GenUI yet, so this prototype
 * is served from one shared workstation. Remove this once GenUI ships and
 * users run their own DevTools.
 */
const hostedDevToolsHosts = ['jakemac0.c.googlers.com'];

/**
 * Redirects an `http://` URL on a corp host to its HTTPS ÜberProxy address.
 *
 * The pane is usually served over HTTPS, so it can't frame `http://` pages
 * (mixed content); this redirector makes the browser load the HTTPS address
 * instead.
 */
const uberProxyRedirector =
  'https://uberproxy-pen-redirect.corp.google.com/uberproxy/pen';

/** Parses [raw] as a URL with one of [protocols], or returns null. */
function parseUrl(raw, protocols) {
  if (!raw) return null;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  return protocols.includes(url.protocol) ? url : null;
}

/** Parses [raw] as a URL, returning null if it is not a loopback URL. */
function parseLoopbackUrl(raw, protocols) {
  const url = parseUrl(raw, protocols);
  if (!url || !loopbackHosts.includes(url.hostname) || !url.port) return null;
  return url;
}

/**
 * Returns the path of [url] (a loopback URL) through the backend's
 * `/proxy/<port>/` route; see main.mjs for why this is needed.
 */
function proxyPath(url) {
  return `/proxy/${url.port}${url.pathname}${url.search}`;
}

/**
 * Returns the address to load the DevTools page [devTools] from, or null if
 * the pane doesn't show DevTools from that host.
 *
 * Only DevTools on this machine (loaded through the backend proxy) and the
 * [hostedDevToolsHosts] are allowed, so a crafted link can't frame an
 * arbitrary site.
 */
function devToolsFrameUrl(devTools) {
  if (loopbackHosts.includes(devTools.hostname) && devTools.port) {
    return new URL(proxyPath(devTools), location.origin);
  }
  if (hostedDevToolsHosts.includes(devTools.hostname)) {
    if (devTools.protocol === 'https:' || location.protocol !== 'https:') {
      return devTools;
    }
    const redirect = new URL(uberProxyRedirector);
    redirect.searchParams.set('url', devTools.toString());
    return redirect;
  }
  return null;
}

/**
 * Returns the DevTools URL [raw] rewritten for the pane, or null if the pane
 * doesn't show it (see [devToolsFrameUrl]).
 */
function parseDevToolsUrl(raw) {
  const devTools = parseUrl(raw, ['http:', 'https:']);
  if (!devTools) return null;
  // DevTools connects to the app's VM service from the browser, which may be
  // on another machine, so route that connection through the backend proxy.
  const vmService = parseLoopbackUrl(devTools.searchParams.get('uri'), [
    'ws:',
    'wss:',
    'http:',
    'https:',
  ]);
  if (vmService) {
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const proxied = new URL(
      `${scheme}//${location.host}${proxyPath(vmService)}`,
    );
    // Authenticate the WebSocket with the host gateway's token rather than
    // relying on its session cookie, which isn't sent (or accepted) for the
    // WebSocket handshake, especially from a hosted DevTools origin. The
    // backend strips it before forwarding.
    if (sidecarToken) proxied.searchParams.set('token', sidecarToken);
    devTools.searchParams.set('uri', proxied.toString());
  }
  // Hide the DevTools screen tabs; the pane only shows one page.
  if (!devTools.searchParams.has('embedMode')) {
    devTools.searchParams.set('embedMode', 'one');
  }
  return devToolsFrameUrl(devTools);
}

function show(url, rawUrl) {
  frame.src = url.toString();
  frame.hidden = false;
  empty.hidden = true;
  localStorage.setItem(lastUrlKey, rawUrl);
}

function showStatus(text) {
  status.textContent = text;
  status.hidden = false;
  clearTimeout(showStatus.timer);
  showStatus.timer = setTimeout(() => (status.hidden = true), 3000);
}

/**
 * The host passes the owning conversation and the backend auth token to the
 * pane as query parameters.
 */
const hostParams = new URLSearchParams(location.search);
const conversationId = hostParams.get('conversationId');
const sidecarToken = hostParams.get('token');

/** Sends [message] to the conversation via the backend (see main.mjs). */
async function sendMessage(message) {
  const headers = { 'Content-Type': 'application/json' };
  if (sidecarToken) headers['X-Sidecar-Token'] = sidecarToken;
  const response = await fetch('/api/send-message', {
    method: 'POST',
    headers,
    body: JSON.stringify({ conversationId, message }),
  });
  if (!response.ok) throw new Error(await response.text());
}

async function forwardToAgent(message, sentStatus) {
  try {
    await sendMessage(message);
    showStatus(sentStatus);
  } catch (e) {
    showStatus(`Could not reach the agent: ${e}`);
  }
}

function forwardEvent(event) {
  forwardToAgent(
    'The user interacted with the DevTools GenUI page in the side pane:\n' +
      '```json\n' +
      JSON.stringify(event, null, 2) +
      '\n```\n' +
      'Respond using the genUi VM service method (the same event is also ' +
      'returned by its pollEvents command).',
    'Sent your interaction to the agent.',
  );
}

function forwardReady(method) {
  const appUri = new URL(currentRawUrl).searchParams.get('uri');
  forwardToAgent(
    'DevTools GenUI is open in the side pane and connected to the app. ' +
      `Call its \`${method}\` VM service method with the Dart MCP server's ` +
      '`vm_service` tool (`command: callMethod`' +
      (appUri ? `, \`appUri: ${appUri}\`` : '') +
      '); no need to probe other prefixes.',
    'DevTools is ready; told the agent.',
  );
}

window.addEventListener('message', (e) => {
  // Only trust messages from the DevTools frame. Its origin isn't known up
  // front when it loads through the ÜberProxy redirector.
  if (e.source !== frame.contentWindow) return;
  if (!conversationId) return;
  const data = e.data;
  if (data?.type === eventMessageType) {
    forwardEvent(data.event);
  } else if (data?.type === readyMessageType && typeof data.method === 'string') {
    forwardReady(data.method);
  }
});

/** The DevTools URL (as given, before rewriting) shown in the frame. */
let currentRawUrl = null;

/** Shows the DevTools URL [raw], returning false if it is not valid. */
function showRaw(raw) {
  const url = parseDevToolsUrl(raw);
  if (!url) return false;
  currentRawUrl = raw;
  show(url, raw);
  return true;
}

document.getElementById('url-form').addEventListener('submit', (e) => {
  e.preventDefault();
  if (!showRaw(document.getElementById('url-input').value.trim())) {
    showStatus(
      `Enter a DevTools URL on localhost or ${hostedDevToolsHosts.join(', ')}.`,
    );
  }
});

if (
  !showRaw(hostParams.get('url')) &&
  !showRaw(localStorage.getItem(lastUrlKey))
) {
  empty.hidden = false;
}
