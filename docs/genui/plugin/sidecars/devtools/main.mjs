// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

// Sidecar backend for the DevTools GenUI plugin. It serves the shell page
// (index.html), which embeds the DevTools URL the agent passes in, and relays
// the user's GenUI interactions back to the agent's conversation. The agent
// runs DevTools itself; see skills/using-devtools-genui/SKILL.md.
//
// This intentionally has no dependencies (not even the host's `sidecar_sdk`)
// so it runs on any system `node`. The host's environment contract is:
//   - ANTIGRAVITY_SIDECAR_WEB_PORT: the loopback port to serve on.
//   - ANTIGRAVITY_SIDECAR_UI_TOKEN: required (as `X-Sidecar-Token`) on
//     non-GET requests; the host passes it to the page as `?token=`.
//   - ANTIGRAVITY_AGENTAPI_EXE: the language server binary, whose `agentapi`
//     subcommand sends chat messages (falls back to `agentapi` on PATH).

import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** Static files served to the pane, by request path. */
const staticFiles = {
  '/': ['index.html', 'text/html'],
  '/styles.css': ['styles.css', 'text/css'],
  '/shell.js': ['shell.js', 'text/javascript'],
};

/** Maximum accepted request body size, to bound memory use. */
const maxBodyBytes = 1024 * 1024;

const port = parseInt(process.env.ANTIGRAVITY_SIDECAR_WEB_PORT ?? '', 10);
if (!Number.isInteger(port)) {
  throw new Error(
    'ANTIGRAVITY_SIDECAR_WEB_PORT is not set. Is this running as a sidecar?',
  );
}
const uiToken = process.env.ANTIGRAVITY_SIDECAR_UI_TOKEN;

/** Runs `agentapi <args>` and resolves to its parsed JSON output. */
function agentApi(args, { projectId } = {}) {
  const exe = process.env.ANTIGRAVITY_AGENTAPI_EXE;
  const file = exe || 'agentapi';
  const fullArgs = exe ? ['agentapi', ...args] : args;
  const env = { ...process.env };
  if (projectId) env.ANTIGRAVITY_PROJECT_ID = projectId;
  return new Promise((resolve, reject) => {
    execFile(file, fullArgs, { encoding: 'utf-8', env }, (error, stdout) => {
      if (error) return reject(error);
      resolve(stdout.trim() ? JSON.parse(stdout) : {});
    });
  });
}

/** Resolves the project that owns [conversationId], or undefined. */
async function projectIdFor(conversationId) {
  try {
    const data = await agentApi(['get-conversation-metadata', conversationId]);
    const event =
      data?.response?.conversationMetadata ??
      data?.response?.conversation_metadata;
    return event?.metadata?.projectId ?? event?.metadata?.project_id;
  } catch (e) {
    console.error(`Could not resolve the project of ${conversationId}:`, e);
    return undefined;
  }
}

/** Sends [message] to the chat conversation [conversationId]. */
async function sendMessage({ conversationId, message }) {
  if (typeof conversationId !== 'string' || typeof message !== 'string') {
    throw new Error('conversationId and message must be strings');
  }
  const projectId = await projectIdFor(conversationId);
  return agentApi(['send-message', conversationId, message], { projectId });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > maxBodyBytes) {
        reject(new Error('Request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function sendJson(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(value));
}

/**
 * Matches `/proxy/<port>/<rest>`: requests for a server on this machine's
 * loopback interface (DevTools, or the app's VM service).
 *
 * The host serves this pane from a public gateway origin, and browsers block
 * public pages from reaching loopback addresses (Chrome's Local Network
 * Access), so the pane loads DevTools, and DevTools connects to the VM
 * service, through this same-origin proxy instead. The host's gateway has
 * already authenticated every request that reaches this server.
 */
const proxyPathPattern = /^\/proxy\/(\d{1,5})(\/.*)?$/;

/** Returns `{port, path}` for a proxied request URL, or null. */
function parseProxyTarget(requestUrl) {
  const url = new URL(requestUrl, 'http://127.0.0.1');
  const match = proxyPathPattern.exec(url.pathname);
  if (!match) return null;
  const targetPort = parseInt(match[1], 10);
  if (targetPort < 1 || targetPort > 65535 || targetPort === port) return null;
  // The pane may add the gateway's `token` to authenticate requests that
  // can't rely on its cookie (see shell.js); don't forward it.
  url.searchParams.delete('token');
  return { port: targetPort, path: (match[2] ?? '/') + url.search };
}

/** Request headers to forward to a proxied server. */
function proxiedHeaders(req, targetPort) {
  const headers = { ...req.headers, host: `127.0.0.1:${targetPort}` };
  // The gateway adds the sidecar token; it is not meant for other servers.
  delete headers['x-sidecar-token'];
  // The VM service (and DDS) reject WebSocket connections from non-localhost
  // origins, and the pane's origin is the public gateway. The gateway has
  // already authenticated this request, so present the target's own origin.
  if (headers.origin) headers.origin = `http://127.0.0.1:${targetPort}`;
  return headers;
}

function proxyHttp(req, res, target) {
  const upstream = httpRequest(
    {
      host: '127.0.0.1',
      port: target.port,
      method: req.method,
      path: target.path,
      headers: proxiedHeaders(req, target.port),
    },
    (upstreamRes) => {
      const headers = { ...upstreamRes.headers };
      // Keep absolute-path redirects inside the proxy prefix.
      if (headers.location?.startsWith('/')) {
        headers.location = `/proxy/${target.port}${headers.location}`;
      }
      res.writeHead(upstreamRes.statusCode ?? 502, headers);
      upstreamRes.pipe(res);
    },
  );
  upstream.on('error', (e) => {
    console.error(`[proxy] ${req.method} ${req.url} failed: ${e.message}`);
    if (!res.headersSent) res.writeHead(502);
    res.end(`Could not reach 127.0.0.1:${target.port}: ${e.message}`);
  });
  req.pipe(upstream);
}

/** Tunnels a WebSocket upgrade (e.g. the VM service connection). */
function proxyUpgrade(req, socket, head, target) {
  console.log(`[proxy] WebSocket ${req.url}`);
  const upstream = connect(target.port, '127.0.0.1', () => {
    const headerLines = Object.entries(proxiedHeaders(req, target.port))
      .flatMap(([name, value]) =>
        (Array.isArray(value) ? value : [value]).map((v) => `${name}: ${v}`),
      )
      .join('\r\n');
    upstream.write(
      `${req.method} ${target.path} HTTP/1.1\r\n${headerLines}\r\n\r\n`,
    );
    if (head?.length) upstream.write(head);
    upstream.once('data', (chunk) => {
      const statusLine = chunk.toString('latin1').split('\r\n', 1)[0];
      console.log(`[proxy] WebSocket ${req.url}: ${statusLine}`);
    });
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  const close = () => {
    upstream.destroy();
    socket.destroy();
  };
  upstream.on('error', (e) => {
    console.error(`[proxy] WebSocket ${req.url} failed: ${e.message}`);
    close();
  });
  socket.on('error', close);
  upstream.on('close', close);
  socket.on('close', close);
}

const server = createServer(async (req, res) => {
  const { pathname } = new URL(req.url, `http://127.0.0.1:${port}`);

  const proxyTarget = parseProxyTarget(req.url);
  if (proxyTarget) {
    proxyHttp(req, res, proxyTarget);
    return;
  }

  if (req.method === 'GET' && pathname in staticFiles) {
    const [name, contentType] = staticFiles[pathname];
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(readFileSync(join(here, name)));
    return;
  }

  if (req.method === 'POST' && pathname === '/api/send-message') {
    if (uiToken && req.headers['x-sidecar-token'] !== uiToken) {
      sendJson(res, 401, { error: 'unauthorized' });
      return;
    }
    try {
      const result = await sendMessage(JSON.parse(await readBody(req)));
      sendJson(res, 200, result);
    } catch (e) {
      sendJson(res, 500, { error: `${e.message ?? e}` });
    }
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.on('upgrade', (req, socket, head) => {
  const proxyTarget = parseProxyTarget(req.url);
  if (!proxyTarget) {
    socket.destroy();
    return;
  }
  proxyUpgrade(req, socket, head, proxyTarget);
});

// Loopback only: the host's gateway forwards authenticated requests here.
server.listen(port, '127.0.0.1', () => {
  console.log(`[devtools_genui] listening on 127.0.0.1:${port}`);
});
