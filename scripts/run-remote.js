#!/usr/bin/env node
// Non-interactive command runner for the iPad Claude MicroVM (SHELL_INGRESS).
// Usage: node scripts/run-remote.js 'command to run' [timeout-seconds]
// Prints the command's output between BEGIN/END markers and exits.

const { spawnSync } = require('child_process');
const path = require('path');
const WebSocket = require(path.join(__dirname, 'node_modules/ws'));

const cmd = process.argv[2];
const timeoutSec = parseInt(process.argv[3] || '120', 10);
if (!cmd) { console.error('Usage: run-remote.js <command> [timeout-sec]'); process.exit(1); }

function aws(...parts) {
  const r = spawnSync('aws', [...parts, '--profile', 'demo', '--region', 'us-east-1', '--output', 'text'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr?.trim());
  return r.stdout.trim();
}

const mvmId = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-identifier', '--query', 'Parameter.Value');
const endpoint = aws('ssm', 'get-parameter', '--name', '/ipad-claude/mvm-endpoint', '--query', 'Parameter.Value');
const token = aws('lambda-microvms', 'create-microvm-shell-auth-token',
  '--microvm-identifier', mvmId, '--expiration-in-minutes', '10',
  '--query', 'authToken."X-aws-proxy-auth"');

const ws = new WebSocket(endpoint.replace(/^https?:\/\//, 'wss://') + '/',
  ['lambda-microvms', `lambda-microvms.authentication.${token}`, 'shell']);
ws.binaryType = 'nodebuffer';

let out = '';
let started = false;
const START = '__RUN_BEGIN__', END = '__RUN_END__';

const killer = setTimeout(() => {
  console.error(`TIMEOUT after ${timeoutSec}s. Output so far:\n${out}`);
  process.exit(1);
}, timeoutSec * 1000);

ws.on('message', (data) => {
  const s = data.toString('utf8');
  if (!started) {
    if (s.trimStart().startsWith('{"type":"session_init"')) {
      started = true;
      // base64 the command to dodge shell quoting/echo issues
      const b64 = Buffer.from(cmd).toString('base64');
      setTimeout(() => {
        ws.send(`echo ${START}; echo ${b64} | base64 -d | bash 2>&1; echo ${END}\n`);
      }, 300);
      return;
    }
    started = true;
  }
  out += s;
  const beginIdx = out.indexOf(START);
  const endIdx = out.lastIndexOf(END);
  // require END to appear after the echoed command line (both markers appear
  // once in the echoed input line; real ones are on their own lines)
  // strip ANSI/DEC escape sequences (e.g. bracketed-paste \x1b[?2004h) before matching
  const lines = out.split('\n').map(l => l.replace(/\r/g, '').replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, ''));
  const bLine = lines.findIndex(l => l.trim() === START);
  const eLine = lines.findIndex(l => l.trim() === END);
  if (bLine !== -1 && eLine !== -1 && eLine > bLine) {
    clearTimeout(killer);
    console.log(lines.slice(bLine + 1, eLine).join('\n'));
    ws.close();
    process.exit(0);
  }
});

ws.on('error', (e) => { console.error('WS error:', e.message); process.exit(1); });
ws.on('close', () => { console.error('Connection closed before command finished.\n' + out); process.exit(1); });
