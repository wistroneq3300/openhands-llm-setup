// OpenHands Agent Canvas — HTTPS front for the existing HTTP ingress.
// Terminates TLS on 0.0.0.0:3443 and transparently pipes the raw bytes to
// 127.0.0.1:3000 (agent-canvas ingress). Being a byte-level relay it works
// for HTTP, SSE streaming, large uploads and WebSocket (/sockets) alike.
'use strict';

const tls = require('node:tls');
const net = require('node:net');
const fs = require('node:fs');

const PORT = Number(process.env.PROXY_PORT || 3443);
const HOST = process.env.PROXY_HOST || '0.0.0.0';
const BACKEND_HOST = process.env.BACKEND_HOST || '127.0.0.1';
const BACKEND_PORT = Number(process.env.BACKEND_PORT || 3000);
const CERT_DIR = process.env.CERT_DIR || '/opt/openhands-https/certs';

const tlsOptions = {
  key: fs.readFileSync(`${CERT_DIR}/key.pem`),
  cert: fs.readFileSync(`${CERT_DIR}/cert.pem`),
};

let active = 0;

const server = tls.createServer(tlsOptions, (client) => {
  const backend = net.connect(BACKEND_PORT, BACKEND_HOST);
  active += 1;
  const label = `tls=${client._getPeerCertificate ? 'ok' : '?'}`;

  const teardown = (err) => {
    if (err) process.stdout.write(`${new Date().toISOString()} error: ${err.message}\n`);
    client.destroy();
    backend.destroy();
  };
  client.on('error', teardown);
  backend.on('error', teardown);
  client.on('close', () => {
    active = Math.max(0, active - 1);
    backend.end();
  });
  backend.on('close', () => client.end());

  // Byte-level relay. The only transformation we do is injecting
  // X-Forwarded-Proto (and friends) into the first HTTP header block that
  // arrives from the browser. Without it the backend cannot tell this is
  // an HTTPS connection, so the workspace-session cookie is sent without
  // `Secure` and the browser (correctly) refuses to store it, which shows
  // up as 401 on /api/conversations/**/workspace/* reads.
  // We only touch the first request so WebSocket/SSE framing is untouched
  // after the handshake bytes have passed through.
  // We take over the client->backend direction entirely with the 'data'
  // handler below (no client.pipe(backend)) so the first HTTP header block
  // can be rewritten exactly once. A leftover pipe would double-write the
  // same bytes and corrupt a WebSocket upgrade that follows the handshake.
  let headerDone = false;
  client.on('data', (chunk) => {
    if (!headerDone) {
      headerDone = true;
      const sep = chunk.indexOf('\r\n\r\n');
      if (sep !== -1) {
        const head = chunk.subarray(0, sep);
        const rest = chunk.subarray(sep);
        const extra = Buffer.from('\r\nX-Forwarded-Proto: https');
        backend.write(Buffer.concat([head, extra, rest]));
        return;
      }
    }
    backend.write(chunk);
  });
  backend.pipe(client);
  process.stdout.write(`${new Date().toISOString()} relay +1 (${label}, active=${active})\n`);
});

server.listen(PORT, HOST, () => {
  process.stdout.write(
    `[openhands-https] TLS relay listening on ${HOST}:${PORT} -> ${BACKEND_HOST}:${BACKEND_PORT}\n`
  );
});

function shutdown() {
  process.stdout.write(`${new Date().toISOString()} shutting down\n`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
