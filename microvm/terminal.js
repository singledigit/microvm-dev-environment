// Node.js WebSocket terminal server — persistent PTY, ttyd-compatible protocol
// One global shell process; clients attach/detach without killing it.
const http = require('http');
const WebSocket = require('/opt/app/node_modules/ws');

let ptyLib = null;
try {
  ptyLib = require('/opt/app/node_modules/node-pty');
} catch (e) {
  console.warn('node-pty unavailable:', e.message);
}

const PORT = 8080;
const SHELL = '/usr/bin/bash';
const SHELL_ENV = {
  HOME: '/home/coder',
  PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
  TERM: 'xterm-256color',
  LANG: 'en_US.UTF-8',
  USER: 'coder',
  LOGNAME: 'coder',
  SHELL: '/usr/bin/bash',
  CLAUDE_CODE_USE_BEDROCK: '1',
  AWS_REGION: 'us-east-1',
  ANTHROPIC_MODEL: 'us.anthropic.claude-opus-4-8',
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
  DISABLE_AUTOUPDATER: '1',
  DO_NOT_TRACK: '1',
};

const SCROLLBACK_MAX = 150 * 1024; // 150 KB — enough for a full Claude session view
let scrollback = Buffer.alloc(0);
let globalPty = null;
let ptyCols = 220;
let ptyRows = 50;
let shellStarted = false;
const clients = new Set();
const pendingClients = new Set(); // connected but waiting for shell to start

function appendScrollback(data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const combined = Buffer.concat([scrollback, buf]);
  scrollback = combined.length > SCROLLBACK_MAX
    ? combined.slice(combined.length - SCROLLBACK_MAX)
    : combined;
}

function sendOutput(ws, data) {
  if (ws.readyState !== WebSocket.OPEN) return;
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const msg = Buffer.alloc(1 + buf.length);
  msg[0] = 0x30; // cmd '0' = output
  buf.copy(msg, 1);
  ws.send(msg);
}

function broadcast(data) {
  for (const ws of clients) sendOutput(ws, data);
}

function broadcastAll(data) {
  for (const ws of clients) sendOutput(ws, data);
  for (const ws of pendingClients) sendOutput(ws, data);
}

const fs = require('fs');
const HOME_READY = '/tmp/home-ready';

// MOUNT_RETRIES * (MOUNT_TIMEOUT_MS + MOUNT_RETRY_DELAY_MS) = 6 * 35s = 210s max
// Add a small buffer on top.
const WAIT_TIMEOUT_MS = 240000;

function waitForHome(cb) {
  if (fs.existsSync(HOME_READY)) { cb(); return; }
  console.log('Waiting for home mount...');
  let elapsed = 0;
  let lastDotCount = 0;

  // Initial message
  broadcastAll('\r\n\x1b[36mMounting workspace\x1b[0m');

  const iv = setInterval(() => {
    elapsed += 500;

    // Animate dots every 500ms
    const dotCount = Math.floor(elapsed / 500) % 4;
    if (dotCount !== lastDotCount) {
      lastDotCount = dotCount;
      const dots = '.'.repeat(dotCount);
      const pad = ' '.repeat(3 - dotCount);
      // Overwrite the dots portion only (ESC[K clears to end of line)
      broadcastAll(`\r\x1b[36mMounting workspace${dots}${pad}\x1b[0m`);
    }

    if (fs.existsSync(HOME_READY)) {
      clearInterval(iv);
      broadcastAll('\r\n'); // newline after the dots line
      if (fs.existsSync('/tmp/home-ready-failed')) {
        broadcastAll('\x1b[31m[Workspace mount failed — running without persistence]\x1b[0m\r\n');
      } else {
        broadcastAll('\x1b[32m[Workspace mounted]\x1b[0m\r\n');
      }
      cb();
    } else if (elapsed >= WAIT_TIMEOUT_MS) {
      clearInterval(iv);
      broadcastAll('\r\n\x1b[31m[Workspace mount timed out — running without persistence]\x1b[0m\r\n');
      console.warn('waitForHome timed out');
      cb();
    }
  }, 500);
}

function startShell() {
  if (!ptyLib) {
    console.error('node-pty not available — cannot start shell');
    return;
  }
  waitForHome(() => _spawnShell());
}

function _spawnShell() {
  console.log(`Starting shell (${ptyCols}x${ptyRows})…`);
  try {
    globalPty = ptyLib.spawn(SHELL, [], {
      name: 'xterm-256color',
      cols: ptyCols,
      rows: ptyRows,
      cwd: '/home/coder',
      env: SHELL_ENV,
      uid: 1000,  // run as coder — Claude Code refuses bypassPermissions as root
      gid: 1000,
    });

    globalPty.onData((data) => {
      appendScrollback(data);
      broadcast(data);
    });

    globalPty.onExit(({ exitCode }) => {
      console.log(`Shell exited (code ${exitCode}), restarting in 2 s…`);
      broadcast('\r\n\x1b[33m[Shell exited — restarting…]\x1b[0m\r\n');
      scrollback = Buffer.alloc(0);
      globalPty = null;
      shellStarted = false;
      setTimeout(startShell, 2000);
    });

    console.log(`Shell started (${ptyCols}x${ptyRows})`);

    // Move any clients that were waiting for the shell to start into the active set
    for (const ws of pendingClients) {
      pendingClients.delete(ws);
      if (ws.readyState === 1 /* OPEN */) {
        if (scrollback.length > 0) {
          const sm = Buffer.alloc(1 + scrollback.length);
          sm[0] = 0x30;
          scrollback.copy(sm, 1);
          ws.send(sm);
        }
        clients.add(ws);
      }
    }
  } catch (e) {
    console.error('Shell spawn failed:', e.message);
    setTimeout(startShell, 5000);
  }
} // end _spawnShell

// Shell starts on first client resize, not at startup — so it spawns at the right size.

// ── HTTP server (serves minimal page for smoke-test) ──────────────────────────
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<html><body>Terminal server running.</body></html>');
});

// ── WebSocket server ───────────────────────────────────────────────────────────
const wss = new WebSocket.Server({
  server,
  handleProtocols: (protocols) => protocols.has('tty') ? 'tty' : false,
});

wss.on('connection', (ws) => {
  let authenticated = false;

  ws.on('message', (data, isBinary) => {
    // ── Handshake ──────────────────────────────────────────────────────────────
    if (!authenticated) {
      try {
        const msg = JSON.parse(data.toString());
        if (!('AuthToken' in msg)) return;
        authenticated = true;

        // Title frame
        const title = 'Claude Code';
        const tb = Buffer.alloc(1 + title.length);
        tb[0] = 0x31; tb.write(title, 1);
        ws.send(tb);

        // Prefs frame
        const prefs = '{"enableZmodem":false,"disableLeaveAlert":true}';
        const pb = Buffer.alloc(1 + prefs.length);
        pb[0] = 0x32; pb.write(prefs, 1);
        ws.send(pb);

        // If shell is already running, replay scrollback and join immediately.
        // If not yet started, hold in pendingClients until first resize sets dims.
        if (globalPty) {
          if (scrollback.length > 0) {
            const sm = Buffer.alloc(1 + scrollback.length);
            sm[0] = 0x30;
            scrollback.copy(sm, 1);
            ws.send(sm);
          }
          clients.add(ws);
        } else {
          pendingClients.add(ws);
          // Show mounting status if home isn't ready yet
          if (!fs.existsSync(HOME_READY)) {
            sendOutput(ws, '\r\n\x1b[36mMounting workspace…\x1b[0m\r\n');
          }
        }
      } catch (e) {}
      return;
    }

    // ── Data frames ────────────────────────────────────────────────────────────
    if (!isBinary) return;
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (buf.length === 0) return;
    const cmd = String.fromCharCode(buf[0]);
    const payload = buf.slice(1);

    if (cmd === '0' && globalPty) {
      globalPty.write(payload.toString());
    } else if (cmd === '1') {
      try {
        const dim = JSON.parse(payload.toString());
        if (dim.columns && dim.rows) {
          ptyCols = dim.columns;
          ptyRows = dim.rows;
          if (globalPty) {
            globalPty.resize(ptyCols, ptyRows);
          } else if (!shellStarted) {
            // First resize from first client — spawn shell at real terminal size
            shellStarted = true;
            startShell();
          }
        }
      } catch (e) {}
    }
  });

  ws.on('close', () => { clients.delete(ws); pendingClients.delete(ws); });
  ws.on('error', () => { clients.delete(ws); pendingClients.delete(ws); });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Terminal server on :${PORT}`);
});
