// Lifecycle hooks server — handles suspend/terminate unmount, plus a
// background disk prefetch on /run. Mount is done eagerly in entrypoint.sh
// before this server starts.
const http = require('http');
const fs = require('fs');
const { execSync, spawn } = require('child_process');

const BASE = '/aws/lambda-microvms/runtime/v1';
const MOUNT_PATH = '/home/coder';
let appReady = false;

setTimeout(() => { appReady = true; }, 5000);

let prefetchStarted = false;
function prefetchDisk() {
  if (prefetchStarted) return;
  prefetchStarted = true;
  // Warm exactly the pages a Claude session touches by executing the real
  // startup path once. Demand-paging from snapshot storage is slow (~3MB/s
  // first touch) and bandwidth-limited, so a broad find|cat prefetch competes
  // with the user's own first launch and makes it WORSE — running the actual
  // binary is both targeted and finishes in seconds.
  const child = spawn('/bin/sh', ['-c', [
    'sudo -u coder HOME=/home/coder claude --version',
    'bash -lc true',            // login-shell path: bash, profile, coreutils
    'git --version',
    'echo "warmup done" >> /tmp/hooks.log',
  ].join('; ')], { detached: true, stdio: 'ignore' });
  child.unref();
  console.log('Startup warmup launched');
}

function unmountHome() {
  fs.rmSync('/tmp/home-ready', { force: true });
  try {
    execSync(`umount ${MOUNT_PATH}`, { stdio: 'inherit' });
    console.log(`Unmounted ${MOUNT_PATH}`);
  } catch (e) {
    console.error('Umount failed:', e.message);
  }
}

const server = http.createServer((req, res) => {
  const { url, method } = req;

  if (url === '/health' && method === 'GET') {
    res.writeHead(200); res.end('ok'); return;
  }

  if (url === `${BASE}/ready` && method === 'POST') {
    if (appReady) { res.writeHead(200); res.end(); }
    else { res.writeHead(503); res.end(); }
    return;
  }

  if ((url === `${BASE}/run` || url === `${BASE}/resume`) && method === 'POST') {
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', () => {
      console.log(`Hook: ${url} (mount already done in entrypoint)`);
      res.writeHead(200); res.end();
      // Disk blocks are demand-paged from snapshot storage (~3MB/s first
      // touch). Prefetch what a Claude session needs — node_modules for the
      // terminal server, shared libs, coreutils — in the background at low IO
      // priority so an early keystroke isn't competing with a cold read.
      // The Claude CLI itself lives in tmpfs (memory snapshot), not here.
      if (url === `${BASE}/run`) prefetchDisk();
    });
    return;
  }

  if ((url === `${BASE}/suspend` || url === `${BASE}/terminate`) && method === 'POST') {
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', () => {
      console.log(`Hook: ${url}`);
      unmountHome();
      res.writeHead(200); res.end();
    });
    return;
  }

  res.writeHead(404); res.end();
});

server.listen(9000, '0.0.0.0', () => {
  console.log('Hooks server on :9000');
});
