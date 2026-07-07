#!/usr/bin/env node
// Interactive shell client for a user's iPad Claude MicroVM (SHELL_INGRESS).
// Usage: node tools/exec.js --user <email> [--root]
//   (or set IPAD_CLAUDE_USER=<email> instead of --user)
// Requires: cd tools && npm install  (installs the `ws` client)

const path = require('path');
const WebSocket = require(path.join(__dirname, 'node_modules/ws'));
const { aws, userArg, resolveMvm } = require('./resolve-mvm');

// ── Parse args ────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const email = userArg(args);
const asRoot = args.includes('--root'); // stay as root instead of dropping to coder

async function main() {
  // ── Resolve this user's MicroVM ───────────────────────────────────────────
  let mvmId, endpoint;
  try { ({ mvmId, endpoint } = resolveMvm(email)); }
  catch (e) { console.error(e.message); process.exit(1); }
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
        // SHELL_INGRESS drops us in as root at /. By default switch to the coder
        // user with a login shell (lands in /home/coder, sources .bashrc). With
        // --root, stay as root (for system installs etc). `su --pty` allocates a
        // fresh pseudo-terminal so job control (Ctrl+C/Z, fg/bg) works — without
        // it the nested shell warns "cannot set terminal process group".
        setTimeout(() => {
          if (ws.readyState !== WebSocket.OPEN) return;
          if (asRoot) {
            process.stderr.write('(root shell — system changes do NOT persist across restarts)\n');
            ws.send(`clear\n`);
          } else {
            ws.send(`exec su --pty - coder -c 'clear; exec zsh -l'\n`);
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
