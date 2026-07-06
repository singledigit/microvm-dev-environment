#!/usr/bin/env node
// Validates the terminal server's keepalive pong.
// Connects like the browser (tty subprotocol via HTTP_INGRESS), completes the
// handshake, sends the 1-byte NUL ping, and expects a 1-byte NUL echo back.
// Exit 0 = pong received; exit 1 = anything else.

const { spawnSync } = require('child_process');
const path = require('path');

const WebSocket = require(path.join(__dirname, 'node_modules/ws'));

const profile = 'demo';
const region = 'us-east-1';

function aws(...parts) {
  const cmd = ['aws', ...parts, '--profile', profile, '--region', region, '--output', 'text'];
  const r = spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr?.trim() || `aws command failed: ${parts[0]}`);
  return r.stdout.trim();
}

const mvmId = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-identifier', '--query', 'Parameter.Value');
const endpoint = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-endpoint', '--query', 'Parameter.Value');
const token = aws(
  'lambda-microvms', 'create-microvm-auth-token',
  '--microvm-identifier', mvmId,
  '--expiration-in-minutes', '5',
  '--allowed-ports', '[{"port":8080}]',
  '--query', 'authToken."X-aws-proxy-auth"',
);

console.log(`MVM: ${mvmId}`);
const wsUrl = endpoint.replace(/^https?:\/\//, 'wss://') + '/';
const ws = new WebSocket(wsUrl, [
  'lambda-microvms',
  `lambda-microvms.authentication.${token}`,
  'lambda-microvms.port.8080',
  'tty',
]);
ws.binaryType = 'nodebuffer';

let pingSent = false;
let outputBytes = 0;

const timeout = setTimeout(() => {
  console.error(`FAIL: no pong within 15s of ping (received ${outputBytes} bytes of other traffic)`);
  process.exit(1);
}, 30000);

ws.on('open', () => {
  console.log('Connected, sending handshake...');
  ws.send(JSON.stringify({ AuthToken: '' }));
  // Give the handshake a moment, then send the keepalive ping
  setTimeout(() => {
    console.log('Sending NUL ping...');
    pingSent = true;
    ws.send(Buffer.from([0x00]));
  }, 2000);
});

ws.on('message', (data) => {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (pingSent && buf.length === 1 && buf[0] === 0x00) {
    console.log('PASS: NUL pong received — idle keepalive works');
    clearTimeout(timeout);
    ws.close();
    process.exit(0);
  }
  outputBytes += buf.length;
});

ws.on('error', (err) => {
  console.error(`FAIL: WebSocket error: ${err.message}`);
  process.exit(1);
});

ws.on('close', (code) => {
  console.error(`FAIL: connection closed (${code}) before pong`);
  process.exit(1);
});
