#!/usr/bin/env node
// Local HTTP/WebSocket relay for DSH Remote.
//
// DSH's /api trust fence accepts loopback Host/Origin values, but Tailscale
// Serve forwards the public tailnet authority.  This relay stays on loopback,
// rewrites those two browser markers, and transparently forwards HTTP,
// streaming responses, and WebSocket upgrades to the real DSH web server.

const http = require('node:http');
const net = require('node:net');

function readArg(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  if (value === undefined || value === '') throw new Error(`missing value for ${name}`);
  return value;
}

function numberArg(name, fallback) {
  const value = Number(readArg(name, fallback));
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`${name} must be a TCP port`);
  }
  return value;
}

const listenHost = readArg('--listen-host', '127.0.0.1');
const listenPort = numberArg('--listen-port', 3090);
const targetHost = readArg('--target-host', '127.0.0.1');
const targetPort = numberArg('--target-port', 3081);
const targetAuthority = `${targetHost}:${targetPort}`;
const targetOrigin = `http://${targetAuthority}`;

function rewriteHeaders(input) {
  const headers = { ...input };
  headers.host = targetAuthority;
  // DSH validates Origin against Host.  Preserve the request semantics while
  // making the forwarded request same-origin with the loopback backend.
  headers.origin = targetOrigin;
  return headers;
}

function writeError(response, statusCode, message) {
  if (response.headersSent) {
    response.destroy();
    return;
  }
  response.writeHead(statusCode, { 'content-type': 'text/plain; charset=utf-8' });
  response.end(message);
}

const server = http.createServer((clientRequest, clientResponse) => {
  const upstream = http.request({
    host: targetHost,
    port: targetPort,
    method: clientRequest.method,
    path: clientRequest.url,
    headers: rewriteHeaders(clientRequest.headers),
  }, (upstreamResponse) => {
    clientResponse.writeHead(
      upstreamResponse.statusCode || 502,
      upstreamResponse.statusMessage,
      upstreamResponse.headers,
    );
    upstreamResponse.pipe(clientResponse);
  });

  upstream.setTimeout(0);
  upstream.on('error', (error) => {
    if (!clientResponse.destroyed) writeError(clientResponse, 502, `DSH relay upstream error: ${error.message}`);
  });
  clientRequest.on('aborted', () => upstream.destroy());
  clientResponse.on('close', () => upstream.destroy());
  clientRequest.pipe(upstream);
});

server.on('upgrade', (clientRequest, clientSocket, head) => {
  const upstreamSocket = net.connect({ host: targetHost, port: targetPort });
  let connected = false;

  upstreamSocket.once('connect', () => {
    connected = true;
    const lines = [`${clientRequest.method} ${clientRequest.url} HTTP/${clientRequest.httpVersion}`];
    for (const [name, value] of Object.entries(rewriteHeaders(clientRequest.headers))) {
      if (Array.isArray(value)) {
        for (const item of value) lines.push(`${name}: ${item}`);
      } else if (value !== undefined) {
        lines.push(`${name}: ${value}`);
      }
    }
    lines.push('', '');
    upstreamSocket.write(lines.join('\r\n'));
    if (head.length > 0) upstreamSocket.write(head);
    clientSocket.pipe(upstreamSocket);
    upstreamSocket.pipe(clientSocket);
  });

  const reject = (error) => {
    if (connected) return;
    clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 17\r\n\r\nDSH relay offline');
    if (error) process.stderr.write(`[dsh-remote-relay] ${error.message}\n`);
  };
  upstreamSocket.once('error', reject);
  clientSocket.once('error', () => upstreamSocket.destroy());
  clientSocket.once('close', () => upstreamSocket.destroy());
});

server.on('clientError', (error, socket) => {
  socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  process.stderr.write(`[dsh-remote-relay] client error: ${error.message}\n`);
});

function shutdown(signal) {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
  process.stderr.write(`[dsh-remote-relay] stopping on ${signal}\n`);
}

process.once('SIGINT', () => shutdown('SIGINT'));
process.once('SIGTERM', () => shutdown('SIGTERM'));

server.listen({ host: listenHost, port: listenPort }, () => {
  process.stdout.write(`[dsh-remote-relay] listening on ${listenHost}:${listenPort} -> ${targetAuthority}\n`);
});

