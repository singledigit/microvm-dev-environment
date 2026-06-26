#!/usr/bin/env node
// Local shell client for the iPad Claude MicroVM.
// Usage: node scripts/exec.js [--profile <profile>] [--region <region>]
// Requires: npm install ws  (or uses cdk/node_modules/ws if present)

const { spawnSync } = require('child_process');
const path = require('path');

const WS_MOD = (() => {
  const candidates = [
    path.join(__dirname, 'node_modules/ws'),
    path.join(__dirname, '../cdk/node_modules/ws'),
  ];
  for (const p of candidates) {
    try { return require(p); } catch {}
  }
  console.error('ws module not found. Run: cd scripts && npm install');
  process.exit(1);
})();
const WebSocket = WS_MOD;

// ── Parse args ────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const profile = args[args.indexOf('--profile') + 1] || 'demo';
const region  = args[args.indexOf('--region')  + 1] || 'us-east-1';

function aws(...parts) {
  const cmd = ['aws', ...parts, '--profile', profile, '--region', region, '--output', 'text'];
  const r = spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr?.trim() || `aws command failed: ${parts[0]}`);
  return r.stdout.trim();
}

async function main() {
  // ── Get MVM ID + endpoint from SSM ────────────────────────────────────────
  process.stderr.write('Fetching MicroVM info from SSM...\n');
  let mvmId, endpoint;
  try {
    mvmId    = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-identifier', '--query', 'Parameter.Value');
    endpoint = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-endpoint',   '--query', 'Parameter.Value');
  } catch (e) {
    console.error('Could not read SSM params:', e.message);
    process.exit(1);
  }
  process.stderr.write(`MVM: ${mvmId}\n`);

  // ── Mint shell auth token ─────────────────────────────────────────────────
  process.stderr.write('Minting shell auth token...\n');
  let shellToken;
  try {
    shellToken = aws(
      'lambda-microvms', 'create-microvm-shell-auth-token',
      '--microvm-identifier', mvmId,
      '--expiration-in-minutes', '60',
      '--query', 'authToken."X-aws-proxy-auth"',
    );
  } catch (e) {
    console.error('Failed to mint shell token:', e.message);
    process.exit(1);
  }

  if (!shellToken || shellToken === 'None') {
    console.error('Shell token came back empty.');
    process.exit(1);
  }

  // ── Connect via WebSocket ─────────────────────────────────────────────────
  const wsUrl = endpoint.replace(/^https?:\/\//, 'wss://') + '/';
  process.stderr.write(`Connecting to ${wsUrl}...\n`);

  const protocols = [
    'lambda-microvms',
    `lambda-microvms.authentication.${shellToken}`,
    'shell',
  ];

  const ws = new WebSocket(wsUrl, protocols);
  ws.binaryType = 'nodebuffer';

  let sessionReady = false;

  ws.on('open', () => {
    process.stderr.write('Connected. Press Ctrl+C to exit.\n\n');

    if (process.stdin.isTTY) process.stdin.setRawMode(true);
    process.stdin.resume();

    let lastCtrlC = 0;
    process.stdin.on('data', (chunk) => {
      // Double Ctrl+C within 1s = disconnect
      if (chunk.length === 1 && chunk[0] === 0x03) {
        const now = Date.now();
        if (now - lastCtrlC < 1000) {
          process.stderr.write('\nDisconnecting...\n');
          cleanup();
          ws.close();
          return;
        }
        lastCtrlC = now;
        process.stderr.write('\n(press Ctrl+C again to disconnect)\n');
      }
      if (ws.readyState === WebSocket.OPEN) ws.send(chunk);
    });
  });

  ws.on('message', (data) => {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);

    // SHELL_INGRESS sends a JSON session_init frame first — swallow it silently
    if (!sessionReady) {
      const str = buf.toString('utf8').trimStart();
      if (str.startsWith('{"type":"session_init"')) {
        sessionReady = true;
        // Set terminal size via stty once the shell is ready
        const cols = process.stdout.columns || 220;
        const rows = process.stdout.rows || 50;
        setTimeout(() => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(`stty cols ${cols} rows ${rows} && clear\n`);
          }
        }, 200);
        return;
      }
      sessionReady = true; // unexpected first frame — just pass it through
    }

    process.stdout.write(buf);
  });

  ws.on('close', () => {
    cleanup();
    process.exit(0);
  });

  ws.on('error', (err) => {
    process.stderr.write(`WebSocket error: ${err.message}\n`);
    cleanup();
    process.exit(1);
  });


  function cleanup() {
    process.stdin.pause();
    if (process.stdin.isTTY) {
      try { process.stdin.setRawMode(false); } catch {}
    }
  }
}

main().catch(e => { console.error(e.message); process.exit(1); });
