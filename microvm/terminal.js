// Node.js WebSocket terminal server — persistent PTYs, ttyd-compatible protocol
// Multiple named sessions (one PTY each); clients pick a session in the
// handshake ({AuthToken, session}) and attach/detach without killing it.
// Clients that send no session id get 'main' — the original single-terminal
// behavior. The frontend uses extra sessions for split-screen panes.
const http = require('http');
const WebSocket = require('/opt/app/node_modules/ws');

let ptyLib = null;
try {
  ptyLib = require('/opt/app/node_modules/node-pty');
} catch (e) {
  console.warn('node-pty unavailable:', e.message);
}

const PORT = 8080;
const SHELL = '/usr/bin/zsh';
const SHELL_ENV = {
  HOME: '/home/coder',
  PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
  TERM: 'xterm-256color',
  LANG: 'en_US.UTF-8',
  USER: 'coder',
  LOGNAME: 'coder',
  SHELL: '/usr/bin/zsh',
  CLAUDE_CODE_USE_BEDROCK: '1',
  AWS_REGION: 'us-east-1',
  // Default model: Opus. Fable available via /model us.anthropic.claude-fable-5.
  ANTHROPIC_MODEL: 'us.anthropic.claude-opus-4-8',
  ANTHROPIC_DEFAULT_OPUS_MODEL: 'us.anthropic.claude-opus-4-8',
  ANTHROPIC_DEFAULT_SONNET_MODEL: 'us.anthropic.claude-sonnet-5',
  ANTHROPIC_DEFAULT_HAIKU_MODEL: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
  ANTHROPIC_SMALL_FAST_MODEL: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
  // uv/uvx state on the hardlink-capable system FS (NFS home rejects hardlinks),
  // so the AWS toolkit's uvx-launched MCP proxy runs from the warmed /opt cache.
  UV_CACHE_DIR: '/opt/uv/cache',
  UV_PYTHON_INSTALL_DIR: '/opt/uv/python',
  UV_TOOL_DIR: '/opt/uv/tool',
  UV_TOOL_BIN_DIR: '/opt/uv/toolbin',
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
  DISABLE_AUTOUPDATER: '1',
  DO_NOT_TRACK: '1',
};

const SCROLLBACK_MAX = 150 * 1024; // 150 KB per session — a full Claude session view

// ── Sessions ──────────────────────────────────────────────────────────────────
// id -> { pty, scrollback, cols, rows, clients, pending, shellStarted, killed }
const sessions = new Map();

function getSession(id) {
  let s = sessions.get(id);
  if (!s) {
    s = {
      id,
      pty: null,
      scrollback: Buffer.alloc(0),
      cols: 220,
      rows: 50,
      clients: new Set(),        // attached, receiving PTY output
      pending: new Set(),        // connected, waiting for shell to start
      activeWs: null,            // controlling client — the last one to type owns the PTY size
      shellStarted: false,
      killed: false,             // client asked to close this session for good
    };
    sessions.set(id, s);
  }
  return s;
}

function appendScrollback(session, data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const combined = Buffer.concat([session.scrollback, buf]);
  session.scrollback = combined.length > SCROLLBACK_MAX
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

function broadcast(session, data) {
  for (const ws of session.clients) sendOutput(ws, data);
}

// Every connected socket across all sessions (used for mount-status messages).
function broadcastEveryone(data) {
  for (const s of sessions.values()) {
    for (const ws of s.clients) sendOutput(ws, data);
    for (const ws of s.pending) sendOutput(ws, data);
  }
}

function replayScrollback(session, ws) {
  if (session.scrollback.length === 0) return;
  const sm = Buffer.alloc(1 + session.scrollback.length);
  sm[0] = 0x30;
  session.scrollback.copy(sm, 1);
  ws.send(sm);
}

const fs = require('fs');
const HOME_READY = '/tmp/home-ready';

// MOUNT_RETRIES * (MOUNT_TIMEOUT_MS + MOUNT_RETRY_DELAY_MS) = 6 * 35s = 210s max
// Add a small buffer on top.
const WAIT_TIMEOUT_MS = 240000;

// Shared home-mount wait: the first session to need a shell drives the
// animation; any others started meanwhile just queue their callbacks.
let homeWaiters = null; // null = no wait in progress

function waitForHome(cb) {
  if (fs.existsSync(HOME_READY)) { cb(); return; }
  if (homeWaiters) { homeWaiters.push(cb); return; }
  homeWaiters = [cb];
  console.log('Waiting for home mount...');
  let elapsed = 0;
  let lastDotCount = 0;

  const finish = () => {
    const waiters = homeWaiters;
    homeWaiters = null;
    for (const fn of waiters) fn();
  };

  // Initial message
  broadcastEveryone('\r\n\x1b[36mMounting workspace\x1b[0m');

  const iv = setInterval(() => {
    elapsed += 500;

    // Animate dots every 500ms
    const dotCount = Math.floor(elapsed / 500) % 4;
    if (dotCount !== lastDotCount) {
      lastDotCount = dotCount;
      const dots = '.'.repeat(dotCount);
      const pad = ' '.repeat(3 - dotCount);
      // Overwrite the dots portion only (ESC[K clears to end of line)
      broadcastEveryone(`\r\x1b[36mMounting workspace${dots}${pad}\x1b[0m`);
    }

    if (fs.existsSync(HOME_READY)) {
      clearInterval(iv);
      broadcastEveryone('\r\n'); // newline after the dots line
      if (fs.existsSync('/tmp/home-ready-failed')) {
        broadcastEveryone('\x1b[31m[Workspace mount failed — running without persistence]\x1b[0m\r\n');
      } else {
        broadcastEveryone('\x1b[32m[Workspace mounted]\x1b[0m\r\n');
      }
      finish();
    } else if (elapsed >= WAIT_TIMEOUT_MS) {
      clearInterval(iv);
      broadcastEveryone('\r\n\x1b[31m[Workspace mount timed out — running without persistence]\x1b[0m\r\n');
      console.warn('waitForHome timed out');
      finish();
    }
  }, 500);
}

function startShell(session) {
  if (!ptyLib) {
    console.error('node-pty not available — cannot start shell');
    return;
  }
  waitForHome(() => _spawnShell(session));
}

function _spawnShell(session) {
  if (session.killed) return;
  console.log(`Starting shell [${session.id}] (${session.cols}x${session.rows})…`);
  // This VM's id (written by hooks.js from the /run envelope) — read at spawn
  // time, not module load: the /run hook may land after this server starts.
  // In the env (not just rc files) so it reaches every user, including those
  // whose persistent home was seeded with older rc files.
  let mvmId = '';
  try { mvmId = fs.readFileSync('/tmp/microvm-id', 'utf8').trim(); } catch (e) {}
  try {
    session.pty = ptyLib.spawn(SHELL, [], {
      name: 'xterm-256color',
      cols: session.cols,
      rows: session.rows,
      cwd: '/home/coder',
      env: mvmId ? { ...SHELL_ENV, MICROVM_ID: mvmId } : SHELL_ENV,
      uid: 1000,  // run as coder — Claude Code refuses bypassPermissions as root
      gid: 1000,
    });

    session.pty.onData((data) => {
      appendScrollback(session, data);
      broadcast(session, data);
    });

    session.pty.onExit(({ exitCode }) => {
      session.pty = null;
      if (session.killed) {
        console.log(`Shell [${session.id}] exited (code ${exitCode}) — session closed`);
        sessions.delete(session.id);
        return;
      }
      console.log(`Shell [${session.id}] exited (code ${exitCode}), restarting in 2 s…`);
      broadcast(session, '\r\n\x1b[33m[Shell exited — restarting…]\x1b[0m\r\n');
      session.scrollback = Buffer.alloc(0);
      session.shellStarted = false;
      setTimeout(() => startShell(session), 2000);
    });

    console.log(`Shell started [${session.id}] (${session.cols}x${session.rows})`);

    // Move any clients that were waiting for the shell to start into the active set
    for (const ws of session.pending) {
      session.pending.delete(ws);
      if (ws.readyState === 1 /* OPEN */) {
        replayScrollback(session, ws);
        session.clients.add(ws);
      }
    }
  } catch (e) {
    console.error(`Shell spawn failed [${session.id}]:`, e.message);
    setTimeout(() => startShell(session), 5000);
  }
} // end _spawnShell

// A client closed its pane for good: kill the PTY and forget the session.
function killSession(session) {
  session.killed = true;
  if (session.pty) {
    try { session.pty.kill(); } catch (e) {}
    // onExit deletes the session
  } else {
    sessions.delete(session.id);
  }
  session.clients.clear();
  session.pending.clear();
  console.log(`Session [${session.id}] killed by client`);
}

// Shells start on first client resize, not at startup — so each spawns at the right size.

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
  let session = null;

  ws.on('message', (data, isBinary) => {
    // ── Handshake ──────────────────────────────────────────────────────────────
    if (!authenticated) {
      try {
        const msg = JSON.parse(data.toString());
        if (!('AuthToken' in msg)) return;
        authenticated = true;

        // Session pick: sanitized id from the handshake, or 'main' (legacy clients).
        const rawId = typeof msg.session === 'string' ? msg.session : 'main';
        const id = rawId.replace(/[^\w-]/g, '').slice(0, 32) || 'main';
        session = getSession(id);

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

        // If the shell is already running, replay scrollback and join immediately.
        // If not yet started, hold in pending until first resize sets dims.
        if (session.pty) {
          replayScrollback(session, ws);
          session.clients.add(ws);
        } else {
          session.pending.add(ws);
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

    // Keepalive: the client sends a single NUL byte every 15s. Echo it back so
    // the client's liveness timer sees traffic even when the PTY is idle —
    // without this, an idle prompt looks like a dead socket and the client
    // closes/reopens the connection every 45s.
    if (buf.length === 1 && buf[0] === 0x00) {
      ws.send(buf);
      return;
    }

    const cmd = String.fromCharCode(buf[0]);
    const payload = buf.slice(1);

    if (cmd === '0' && session.pty) {
      // Typing takes size control (tmux `window-size latest` behavior): the
      // device being USED sets the PTY size, so a phone glancing at a desktop
      // session doesn't shrink it — but starts controlling once it types.
      // ESC-initiated input does NOT claim control: xterm auto-replies to TUI
      // queries (cursor position \x1b[..R, device attributes) through this
      // same path from EVERY attached client, and those must not count as
      // typing. Cost: arrow keys alone don't claim control — fine, since any
      // real interaction includes plain keys almost immediately.
      if (session.activeWs !== ws && payload[0] !== 0x1b) {
        session.activeWs = ws;
        if (ws.dims && (ws.dims.cols !== session.cols || ws.dims.rows !== session.rows)) {
          session.cols = ws.dims.cols;
          session.rows = ws.dims.rows;
          try { session.pty.resize(session.cols, session.rows); } catch (e) {}
        }
      }
      session.pty.write(payload.toString());
    } else if (cmd === '1') {
      try {
        const dim = JSON.parse(payload.toString());
        if (dim.columns && dim.rows) {
          // Remember this client's size, but only the controlling client
          // (last to type — or sole/first client) resizes the shared PTY.
          ws.dims = { cols: dim.columns, rows: dim.rows };
          if (!session.activeWs || session.activeWs.readyState !== WebSocket.OPEN) {
            session.activeWs = ws;
          }
          if (session.activeWs === ws) {
            session.cols = dim.columns;
            session.rows = dim.rows;
            if (session.pty) {
              session.pty.resize(session.cols, session.rows);
            } else if (!session.shellStarted && !session.killed) {
              // First resize from first client — spawn shell at real terminal size
              session.shellStarted = true;
              startShell(session);
            }
          } else if (!session.pty && !session.shellStarted && !session.killed) {
            session.shellStarted = true;
            startShell(session);
          }
        }
      } catch (e) {}
    } else if (cmd === '3') {
      // Frontend extension: pane closed for good — kill this session's PTY.
      killSession(session);
    }
  });

  const detach = () => {
    if (!session) return;
    session.clients.delete(ws);
    session.pending.delete(ws);
    // Controlling client left: hand size control to a surviving client so the
    // PTY snaps back (e.g. phone disconnects → desktop regains full width).
    if (session.activeWs === ws) {
      session.activeWs = null;
      for (const other of session.clients) {
        if (other.readyState === WebSocket.OPEN && other.dims) {
          session.activeWs = other;
          session.cols = other.dims.cols;
          session.rows = other.dims.rows;
          if (session.pty) { try { session.pty.resize(session.cols, session.rows); } catch (e) {} }
          break;
        }
      }
    }
  };
  ws.on('close', detach);
  ws.on('error', detach);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Terminal server on :${PORT}`);
});
