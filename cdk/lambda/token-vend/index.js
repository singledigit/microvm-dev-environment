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

function timingSafeCompare(a, b) {
  const ba = Buffer.from(String(a)), bb = Buffer.from(String(b));
  const len = Math.max(ba.length, bb.length);
  const pa = Buffer.alloc(len), pb = Buffer.alloc(len);
  ba.copy(pa); bb.copy(pb);
  return crypto.timingSafeEqual(pa, pb);
}

function sigv4Request(method, hostname, path, body) {
  return new Promise((resolve, reject) => {
    const region = process.env.AWS_REGION;
    const service = 'lambda';
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

async function runNewMvm() {
  const imageArn = process.env.IMAGE_ARN;
  const executionRoleArn = process.env.EXECUTION_ROLE_ARN;
  const networkConnectorArn = process.env.NETWORK_CONNECTOR_ARN;

  const body = {
    imageIdentifier: imageArn,
    executionRoleArn,
    idlePolicy: {
      maxIdleDurationSeconds: 1800,
      suspendedDurationSeconds: 600,
      autoResumeEnabled: true,
    },
    maximumDurationInSeconds: 28800,
    ingressNetworkConnectors: [
      'arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:HTTP_INGRESS',
    ],
    ...(networkConnectorArn ? { egressNetworkConnectors: [networkConnectorArn] } : {}),
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
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-Login-Email,X-Login-Password',
  };

  const method = event.requestContext?.http?.method || event.httpMethod || 'GET';
  if (method === 'OPTIONS') {
    return { statusCode: 200, headers: corsHeaders, body: '' };
  }

  // ── Auth ──────────────────────────────────────────────────────────────────
  const reqHeaders = event.headers || {};
  const suppliedPw = reqHeaders['x-login-password'] || reqHeaders['X-Login-Password'] || '';
  const isAuthCheck = (event.queryStringParameters?.auth === '1');

  let storedPw;
  try {
    storedPw = await getParam('/ipad-claude/password', true);
  } catch (e) {
    return { statusCode: 500, headers: corsHeaders, body: JSON.stringify({ error: 'Config error' }) };
  }

  if (!suppliedPw || !timingSafeCompare(suppliedPw, storedPw)) {
    return { statusCode: 401, headers: corsHeaders, body: JSON.stringify({ error: 'Unauthorized' }) };
  }

  // Auth-only check (login screen validation)
  if (isAuthCheck) {
    return { statusCode: 200, headers: corsHeaders, body: JSON.stringify({ ok: true }) };
  }

  // ── Ensure a live MicroVM exists ──────────────────────────────────────────
  try {
    let mvmId = '';
    let mvmEndpoint = '';

    try {
      [mvmId, mvmEndpoint] = await Promise.all([
        getParam('/ipad-claude/mvm-identifier'),
        getParam('/ipad-claude/mvm-endpoint'),
      ]);
    } catch (e) {
      console.log('SSM params missing, will launch new MVM');
    }

    if (mvmId) {
      const state = await getMvmState(mvmId);
      console.log(`MVM ${mvmId} state: ${state}`);

      if (state === 'RUNNING') {
        // Happy path
      } else if (state === 'SUSPENDED') {
        console.log('Resuming suspended MVM…');
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
      console.log('Launching new MicroVM…');
      const result = await runNewMvm();
      mvmId = result.mvmId;
      mvmEndpoint = result.endpoint;
      // Persist so future calls (and deploy script) see the new IDs
      await Promise.all([
        putParam('/ipad-claude/mvm-identifier', mvmId),
        putParam('/ipad-claude/mvm-endpoint', mvmEndpoint),
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
      body: JSON.stringify({ authToken, endpoint, expiresInSeconds: 55 * 60 }),
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
