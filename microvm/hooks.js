// Lifecycle hooks server. The per-user S3 Files home is mounted HERE (on /run
// and /resume), not in entrypoint.sh: the image snapshot is shared across all
// VMs, so the mount can't be baked in at build time — each VM mounts its own
// user's access point at run time, and the access-point id arrives in the /run
// payload. Also handles suspend/terminate unmount and the /validate image
// hook, which drives the platform's page prefetch (the cold-start fix).
const http = require('http');
const fs = require('fs');
const { execSync, spawn } = require('child_process');

const BASE = '/aws/lambda-microvms/runtime/v1';
const MOUNT_PATH = '/home/coder';
const AP_FILE = '/tmp/access-point-id';
const MVM_ID_FILE = '/tmp/microvm-id';
const MVM_EP_FILE = '/tmp/microvm-endpoint';

// The public endpoint isn't derivable from the VM id and may not be in the
// /run envelope — ask the control plane about ourselves (execution role has
// PowerUserAccess, so get-microvm is allowed). Background + best-effort.
function lookupEndpoint(mvmId) {
  const region = process.env.AWS_REGION || 'us-east-1';
  const child = spawn('/bin/sh', ['-c',
    `EP=$(aws lambda-microvms get-microvm --microvm-identifier "${mvmId}" ` +
    `--region "${region}" --query endpoint --output text 2>/dev/null); ` +
    'EP=${EP#https://}; [ -n "$EP" ] && [ "$EP" != "None" ] && ' +
    `echo "https://$EP" > ${MVM_EP_FILE}; ` +
    'echo "endpoint lookup: [$EP]" >> /tmp/hooks.log'
  ], { detached: true, stdio: 'ignore' });
  child.unref();
}
let appReady = false;
let validateStarted = false;

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

// Pre-warm the uvx-launched AWS MCP proxy so the first Claude session's MCP
// connect doesn't hit a cold uv cache and risk timing out. The version is
// parsed from the plugin's own .mcp.json (the file that actually launches
// it) so the warm can never drift from reality. The plugin cache lives in
// the user home, so this waits for the mount's ready marker (60s cap so a
// failed mount can't wedge it). No match (plugin not installed) → skip.
let mcpWarmStarted = false;
function warmMcpProxy() {
  if (mcpWarmStarted) return;
  mcpWarmStarted = true;
  const waitStart = Date.now();
  const iv = setInterval(() => {
    if (!fs.existsSync('/tmp/home-ready') && Date.now() - waitStart < 60000) return;
    clearInterval(iv);
    const child = spawn('/bin/sh', ['-c',
      'V=$(grep -ho "mcp-proxy-for-aws@[0-9.]*" /home/coder/.claude/plugins/cache/*/*/*/.mcp.json 2>/dev/null | head -1); ' +
        '[ -n "$V" ] && sudo -u coder HOME=/home/coder ' +
        'UV_CACHE_DIR=/opt/uv/cache UV_PYTHON_INSTALL_DIR=/opt/uv/python ' +
        'UV_TOOL_DIR=/opt/uv/tool UV_TOOL_BIN_DIR=/opt/uv/toolbin ' +
        'uvx "$V" --help >/dev/null 2>&1; ' +
        'echo "mcp warm done" >> /tmp/hooks.log'
    ], { detached: true, stdio: 'ignore' });
    child.unref();
    console.log('MCP proxy warm launched');
  }, 250);
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

  if (url === `${BASE}/validate` && method === 'POST') {
    // Build-time validate run: the platform boots a test VM from the fresh
    // snapshot and SAMPLES which disk pages get touched while this hook runs,
    // then prefetches those pages on future launches. So: touch exactly what
    // a real session's cold path needs. Crucially that includes the S3 Files
    // mount toolchain — a validate-time VM gets no runHookPayload, so the
    // per-user mount never runs on its own and the mount stack would never
    // be sampled unless we exercise it here deliberately.
    // Contract: 503 while working, 200 when done (platform polls).
    if (!validateStarted) {
      validateStarted = true;
      const child = spawn('/bin/sh', ['-c', [
        // the real session cold path
        'sudo -u coder HOME=/home/coder claude --version',
        'bash -lc true', 'zsh -lc true || true', 'git --version',
        // the mount toolchain: a REAL mount attempt (bogus access point, so it
        // fails after exercising python3.13, the helpers, and efs-proxy — the
        // failure is the point, the page-touches are what get sampled)
        'mkdir -p /mnt/validate-test',
        'timeout 25 mount -t s3files -o "accesspoint=fsap-0000000000000000f" "$S3_FILES_FS_ID" /mnt/validate-test >/dev/null 2>&1 || true',
        // belt-and-suspenders: read the big binaries end to end for sampling
        'cat /usr/sbin/efs-proxy /usr/bin/node /usr/bin/mount /usr/sbin/mount.nfs > /dev/null 2>&1 || true',
        '/usr/bin/python3.13 -c "import subprocess,ssl,json" || true',
        // the uv cache holds the pre-warmed AWS MCP proxy package (Dockerfile);
        // a session's first MCP connect launches it via uvx, so RUN the real
        // command — paging uv's python, extraction, and env-assembly paths
        // that a byte-level sweep of the cache files would miss. Version must
        // match the Dockerfile pre-warm (no user home at validate time to
        // parse the plugin config from).
        'sudo -u coder HOME=/home/coder ' +
          'UV_CACHE_DIR=/opt/uv/cache UV_PYTHON_INSTALL_DIR=/opt/uv/python ' +
          'UV_TOOL_DIR=/opt/uv/tool UV_TOOL_BIN_DIR=/opt/uv/toolbin ' +
          'timeout 60 uvx mcp-proxy-for-aws@1.6.3 --help >/dev/null 2>&1 || true',
        'find /opt/uv -type f -exec cat {} + > /dev/null 2>&1 || true',
        'touch /tmp/validate-done',
      ].join('; ')], { detached: true, stdio: 'ignore' });
      child.unref();
      console.log('Validate workload launched');
    }
    if (fs.existsSync('/tmp/validate-done')) { res.writeHead(200); res.end(); }
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
      try { fs.appendFileSync('/tmp/hooks.log', `RAW ${url} BODY=[${(body||'').slice(0, 1000)}]\n`); } catch {}
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
        // The platform injects this VM's own id into the /run envelope as
        // microVmId (see skill: iam-and-security.md). Persist it so shells can
        // export MICROVM_ID — users see which VM they're in. Tolerant match
        // (key anywhere, escaped-JSON nesting included) rather than a JSON
        // path, for the same reason as the accessPointId parsing above.
        const idMatch = (body || '').match(/micro[Vv]m[Ii]d\\?["']?\s*:\s*\\?["']?\s*((?:microvm|mvm)-[0-9a-zA-Z-]+)/);
        if (idMatch) fs.writeFileSync(MVM_ID_FILE, idMatch[1]);
        // Endpoint: straight from the envelope if present, else self-lookup.
        const epMatch = (body || '').match(/([\w-]+\.lambda-microvm\.[\w.-]+\.on\.aws)/);
        if (epMatch) fs.writeFileSync(MVM_EP_FILE, `https://${epMatch[1]}`);
        else if (idMatch && !fs.existsSync(MVM_EP_FILE)) lookupEndpoint(idMatch[1]);
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
      if (url === `${BASE}/run`) warmMcpProxy();
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
