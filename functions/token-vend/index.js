const { SSMClient, GetParameterCommand, PutParameterCommand } = require('@aws-sdk/client-ssm');
const https = require('https');
const crypto = require('crypto');

const ssm = new SSMClient({ region: process.env.AWS_REGION });

async function getParam(name, decrypt = false) {
  const r = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: decrypt }));
  return r.Parameter.Value;
}

async function putParam(name, value) {
  await ssm.send(new PutParameterCommand({ Name: name, Value: value, Type: 'String', Overwrite: true }));
}

function sigv4Request(method, hostname, path, body, service = 'lambda') {
  return new Promise((resolve, reject) => {
    const region = process.env.AWS_REGION;
    const accessKey = process.env.AWS_ACCESS_KEY_ID;
    const secretKey = process.env.AWS_SECRET_ACCESS_KEY;
    const sessionToken = process.env.AWS_SESSION_TOKEN;

    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    const dateStamp = now.getUTCFullYear() +
      pad(now.getUTCMonth() + 1) + pad(now.getUTCDate()) + 'T' +
      pad(now.getUTCHours()) + pad(now.getUTCMinutes()) + pad(now.getUTCSeconds()) + 'Z';
    const shortDate = dateStamp.slice(0, 8);
    const bodyStr = body !== undefined ? JSON.stringify(body) : '';
    const bodyHash = crypto.createHash('sha256').update(bodyStr).digest('hex');

    const hdrs = {
      'content-type': 'application/json',
      'host': hostname,
      'x-amz-date': dateStamp,
      'x-amz-content-sha256': bodyHash,
    };
    if (sessionToken) hdrs['x-amz-security-token'] = sessionToken;

    const sortedKeys = Object.keys(hdrs).sort();
    const signedHeaders = sortedKeys.join(';');
    const canonicalHeaders = sortedKeys.map(k => `${k}:${hdrs[k]}`).join('\n') + '\n';
    const canonicalReq = [method, path, '', canonicalHeaders, signedHeaders, bodyHash].join('\n');
    const credScope = `${shortDate}/${region}/${service}/aws4_request`;
    const strToSign = ['AWS4-HMAC-SHA256', dateStamp, credScope,
      crypto.createHash('sha256').update(canonicalReq).digest('hex')].join('\n');

    const sign = (key, msg) => crypto.createHmac('sha256', key).update(msg).digest();
    const sigKey = sign(sign(sign(sign('AWS4' + secretKey, shortDate), region), service), 'aws4_request');
    const signature = crypto.createHmac('sha256', sigKey).update(strToSign).digest('hex');
    hdrs['authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credScope},SignedHeaders=${signedHeaders},Signature=${signature}`;
    hdrs['content-length'] = Buffer.byteLength(bodyStr).toString();

    const req = https.request({ hostname, path, method, headers: hdrs }, res => {
      let data = '';
      res.on('data', d => { data += d; });
      res.on('end', () => {
        if (res.statusCode >= 400) reject(Object.assign(new Error(`API ${res.statusCode} at ${path}: ${data}`), { statusCode: res.statusCode }));
        else resolve(data ? JSON.parse(data) : {});
      });
    });
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

const region = () => process.env.AWS_REGION;
const mvmHost = () => `lambda.${region()}.amazonaws.com`;
const s3filesHost = () => `s3files.${region()}.api.aws`;

// Find-or-create an S3 Files access point scoped to /users/<sub>, so each
// Cognito user gets an isolated home directory on the shared filesystem.
// Idempotent: the access-point id is cached in SSM per user after first login.
async function ensureUserAccessPoint(sub) {
  const fsId = process.env.S3_FILES_FS_ID;
  const cacheParam = `/ipad-claude/users/${sub}/access-point-id`;

  try {
    const cached = await getParam(cacheParam);
    if (cached) return cached;
  } catch (e) { /* not created yet */ }

  const body = {
    fileSystemId: fsId,
    posixUser: { uid: 1000, gid: 1000 },
    rootDirectory: {
      path: `/users/${sub}`,
      creationPermissions: { ownerUid: 1000, ownerGid: 1000, permissions: '0755' },
    },
    clientToken: `ap-${sub}`.slice(0, 64), // idempotent create per user
  };
  const data = await sigv4Request('PUT', s3filesHost(), '/access-points', body, 's3files');
  const apId = data.accessPointId;
  await putParam(cacheParam, apId);
  return apId;
}

async function getMvmState(mvmId) {
  try {
    const data = await sigv4Request('GET', mvmHost(), `/2025-09-09/microvms/${encodeURIComponent(mvmId)}`, undefined);
    return data.state || 'UNKNOWN';
  } catch (e) {
    if (e.statusCode === 404) return 'NOT_FOUND';
    throw e;
  }
}

async function resumeMvm(mvmId) {
  await sigv4Request('POST', mvmHost(), `/2025-09-09/microvms/${encodeURIComponent(mvmId)}/resume`, {});
}

async function terminateMvm(mvmId) {
  await sigv4Request('DELETE', mvmHost(), `/2025-09-09/microvms/${encodeURIComponent(mvmId)}`, undefined);
}

async function runNewMvm(accessPointId) {
  const imageArn = process.env.IMAGE_ARN;
  const executionRoleArn = process.env.EXECUTION_ROLE_ARN;
  const networkConnectorArn = process.env.NETWORK_CONNECTOR_ARN;

  const body = {
    imageIdentifier: imageArn,
    executionRoleArn,
    // Idle = no INBOUND proxy traffic. Outbound work (Claude calling Bedrock)
    // does not reset the clock, so a closed tab means the countdown is running
    // even while a job grinds. 2h keeps kicked-off jobs alive tab-less;
    // maximumDurationInSeconds (8h) is the hard cap either way.
    idlePolicy: {
      maxIdleDurationSeconds: 7200,
      suspendedDurationSeconds: 1800,
      autoResumeEnabled: true,
    },
    maximumDurationInSeconds: 28800,
    ingressNetworkConnectors: [
      `arn:aws:lambda:${region()}:aws:network-connector:aws-network-connector:HTTP_INGRESS`,
      `arn:aws:lambda:${region()}:aws:network-connector:aws-network-connector:SHELL_INGRESS`,
    ],
    ...(networkConnectorArn ? { egressNetworkConnectors: [networkConnectorArn] } : {}),
    // Per-VM data delivered as the body of the /run hook. The hook writes the
    // access-point id to a file that entrypoint.sh reads to mount this user's
    // home directory (see microvm/hooks.js + entrypoint.sh).
    ...(accessPointId ? { runHookPayload: JSON.stringify({ accessPointId }) } : {}),
  };

  const data = await sigv4Request('POST', mvmHost(), '/2025-09-09/microvms', body);
  // API returns microvmId (lowercase v) and endpoint (no protocol prefix)
  const mvmId = data.microvmId;
  const endpoint = data.endpoint?.startsWith('https://') ? data.endpoint : `https://${data.endpoint}`;
  return { mvmId, endpoint };
}

async function mintToken(mvmId) {
  const data = await sigv4Request(
    'POST',
    mvmHost(),
    `/2025-09-09/microvms/${encodeURIComponent(mvmId)}/auth-token`,
    { expirationInMinutes: 55, allowedPorts: [{ port: 8080 }] }
  );
  return data.authToken?.['X-aws-proxy-auth'] || data.authToken;
}

exports.handler = async (event) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin': process.env.ALLOWED_ORIGINS || '*',
    'Access-Control-Allow-Methods': 'GET,DELETE,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
  };

  const method = event.requestContext?.http?.method || event.httpMethod || 'GET';
  if (method === 'OPTIONS') {
    return { statusCode: 200, headers: corsHeaders, body: '' };
  }

  // ── Auth ──────────────────────────────────────────────────────────────────
  // API Gateway's Cognito authorizer already validated the JWT before we ran;
  // the verified claims are in the request context. We just read the user id.
  const claims = event.requestContext?.authorizer?.claims
    || event.requestContext?.authorizer?.jwt?.claims
    || {};
  const sub = claims.sub;
  if (!sub) {
    // Should be unreachable (authorizer blocks unauthenticated calls), but fail
    // closed if the method is ever misconfigured without the authorizer.
    return { statusCode: 401, headers: corsHeaders, body: JSON.stringify({ error: 'Unauthorized' }) };
  }

  // Per-user SSM keys — each user has their own MicroVM + home.
  const mvmIdParam = `/ipad-claude/users/${sub}/mvm-identifier`;
  const mvmEndpointParam = `/ipad-claude/users/${sub}/mvm-endpoint`;

  // ── DELETE /token: terminate THIS user's VM ───────────────────────────────
  // The VM id comes from the caller's own SSM parameter (keyed by their
  // verified Cognito sub) — never from the request — so a user can only ever
  // terminate their own VM. Their home survives (it's the S3 Files mount);
  // the next GET /token launches a fresh VM.
  if (method === 'DELETE') {
    try {
      let mvmId = '';
      try { mvmId = await getParam(mvmIdParam); } catch (e) { /* none yet */ }
      if (mvmId === '-') mvmId = ''; // already terminated earlier
      if (mvmId) {
        try {
          await terminateMvm(mvmId);
          console.log(`User ${sub} terminated their VM ${mvmId}`);
        } catch (e) {
          if (e.statusCode !== 404) throw e; // already gone = success
        }
        // Clear the pointer so the next GET launches fresh instead of finding
        // a TERMINATED VM (also prevents deploy.sh --recreate-image from
        // trying to terminate it again).
        await putParam(mvmIdParam, '-');
      }
      return {
        statusCode: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ terminated: mvmId || null }),
      };
    } catch (err) {
      console.error('Terminate error:', err.message);
      return {
        statusCode: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ error: err.message }),
      };
    }
  }

  // ── Ensure a live MicroVM exists for THIS user ────────────────────────────
  try {
    let mvmId = '';
    let mvmEndpoint = '';
    // Reported to the frontend so it can show "Starting VM…" / "Resuming VM…"
    // instead of alarming reconnect errors while the VM warms up.
    let vmState = 'running';

    try {
      [mvmId, mvmEndpoint] = await Promise.all([
        getParam(mvmIdParam),
        getParam(mvmEndpointParam),
      ]);
    } catch (e) {
      console.log('No MVM for this user yet, will launch one');
    }

    if (mvmId === '-') mvmId = ''; // sentinel from DELETE (SSM forbids empty values)
    if (mvmId) {
      const state = await getMvmState(mvmId);
      console.log(`MVM ${mvmId} state: ${state}`);

      if (state === 'RUNNING') {
        // Happy path
      } else if (state === 'SUSPENDED') {
        console.log('Resuming suspended MVM…');
        vmState = 'resuming';
        await resumeMvm(mvmId);
        // Give it a moment to start accepting connections
        await new Promise(r => setTimeout(r, 3000));
      } else {
        // TERMINATED, NOT_FOUND, UPDATE_FAILED, etc. — launch a new one
        console.log(`MVM state ${state} — launching new MVM…`);
        mvmId = '';
      }
    }

    if (!mvmId) {
      console.log(`Launching new MicroVM for user ${sub}…`);
      vmState = 'starting';
      // Find-or-create this user's home (access point scoped to /users/<sub>).
      const accessPointId = await ensureUserAccessPoint(sub);
      const result = await runNewMvm(accessPointId);
      mvmId = result.mvmId;
      mvmEndpoint = result.endpoint;
      // Persist so future calls see this user's MVM.
      await Promise.all([
        putParam(mvmIdParam, mvmId),
        putParam(mvmEndpointParam, mvmEndpoint),
      ]);
      console.log(`New MVM launched: ${mvmId}`);
      // Give snapshot boot a moment
      await new Promise(r => setTimeout(r, 2000));
    }

    const authToken = await mintToken(mvmId);
    const endpoint = mvmEndpoint.startsWith('https://') ? mvmEndpoint : `https://${mvmEndpoint}`;

    return {
      statusCode: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      body: JSON.stringify({ authToken, endpoint, expiresInSeconds: 55 * 60, vmState }),
    };
  } catch (err) {
    console.error('Token vend error:', err.message);
    return {
      statusCode: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};
