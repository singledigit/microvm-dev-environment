// Lifecycle hooks server. The per-user S3 Files home is mounted HERE (on /run
// and /resume), not in entrypoint.sh: the image snapshot is shared across all
// VMs, so the mount can't be baked in at build time — each VM mounts its own
// user's access point at run time, and the access-point id arrives in the /run
// payload. Also handles suspend/terminate unmount and a startup disk prefetch.
const http = require('http');
const fs = require('fs');
const { execSync, spawn } = require('child_process');

const BASE = '/aws/lambda-microvms/runtime/v1';
const MOUNT_PATH = '/home/coder';
const AP_FILE = '/tmp/access-point-id';
let appReady = false;

setTimeout(() => { appReady = true; }, 5000);

// Mount this user's home in the background and return control immediately —
// the hook must answer 200 within its timeout (~10s) while the mount has its
// own retry budget. terminal.js waits for /tmp/home-ready before spawning the
// shell, so a background mount fits the existing readiness contract.
function mountHome(accessPointId) {
  const child = spawn('/bin/bash', ['/opt/app/mount-home.sh', accessPointId || ''],
    { detached: true, stdio: 'ignore' });
  child.unref();
  console.log(`mountHome launched (accesspoint=${accessPointId || 'none'})`);
}

let prefetchStarted = false;
function prefetchDisk() {
  if (prefetchStarted) return;
  prefetchStarted = true;
  // Wait for the home mount to finish first: demand-paging from snapshot
  // storage is bandwidth-limited (~3MB/s first touch), and the mount is the
  // user-blocking path — warmup running concurrently starves the mount's own
  // page-ins and adds 10s+ to time-to-shell. 60s cap so a failed mount can't
  // block warmup forever.
  const waitStart = Date.now();
  const iv = setInterval(() => {
    if (!fs.existsSync('/tmp/home-ready') && Date.now() - waitStart < 60000) return;
    clearInterval(iv);
    runWarmup();
  }, 250);
}

function runWarmup() {
  // Warm exactly the pages a Claude session touches by executing the real
  // startup path once. Demand-paging from snapshot storage is slow (~3MB/s
  // first touch) and bandwidth-limited, so a broad find|cat prefetch competes
  // with the user's own first launch and makes it WORSE — running the actual
  // binary is both targeted and finishes in seconds.
  const child = spawn('/bin/sh', ['-c', [
    'sudo -u coder HOME=/home/coder claude --version',
    'bash -lc true',            // login-shell path: bash, profile, coreutils
    'zsh -lc true || true',     // the terminal's actual login shell
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
      // /run carries the per-VM runHookPayload with this user's access-point
      // id; persist it so /resume (which has no payload) can reuse it.
      // CONFIRMED delivery shape: the platform wraps our payload in an envelope
      // — body is {"runHookPayload":"{\"accessPointId\":\"fsap-...\"}"} (a
      // JSON string nested inside JSON). We parse defensively (envelope key,
      // raw JSON, and base64 variants) so it's robust to shape changes.
      // The raw body is logged as a one-liner for future diagnosis.
      try { fs.appendFileSync('/tmp/hooks.log', `RAW ${url} BODY=[${(body||'').slice(0, 200)}]\n`); } catch {}
      let accessPointId = '';
      const tryExtract = (s) => {
        if (!s) return '';
        // direct field
        try { const o = JSON.parse(s); if (o && o.accessPointId) return String(o.accessPointId); } catch {}
        return '';
      };
      try {
        const candidates = [];
        const raw = body || '';
        candidates.push(raw);                                   // raw JSON
        try { candidates.push(Buffer.from(raw, 'base64').toString('utf8')); } catch {}
        // envelope: {"runHookPayload":"<raw-or-base64>"} or {"payload":"..."}
        try {
          const env = JSON.parse(raw);
          for (const k of ['runHookPayload', 'payload', 'RunHookPayload']) {
            if (env && typeof env[k] === 'string') {
              candidates.push(env[k]);
              try { candidates.push(Buffer.from(env[k], 'base64').toString('utf8')); } catch {}
            }
          }
        } catch {}
        for (const c of candidates) {
          const ap = tryExtract(c);
          if (ap) { accessPointId = ap; break; }
        }
        if (accessPointId) fs.writeFileSync(AP_FILE, accessPointId);
      } catch (e) {
        console.error('Failed to parse run payload:', e.message);
      }
      if (!accessPointId) {
        // /resume, or a /run without payload — fall back to the persisted id.
        try { accessPointId = fs.readFileSync(AP_FILE, 'utf8').trim(); } catch {}
      }
      console.log(`Hook: ${url} (accesspoint=${accessPointId || 'none'})`);
      // Answer fast; the mount runs in the background (see mountHome).
      res.writeHead(200); res.end();
      mountHome(accessPointId);
      // Warm the demand-paged disk paths a Claude session needs (node_modules,
      // shared libs, coreutils) once per boot. The Claude CLI itself is in
      // tmpfs (memory snapshot), not here.
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
