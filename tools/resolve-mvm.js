// Shared: resolve a user's per-user MicroVM (id + endpoint) from their email.
//
// The token Lambda keys everything on the Cognito `sub`:
//   /ipad-claude/users/<sub>/mvm-identifier
//   /ipad-claude/users/<sub>/mvm-endpoint
// so the break-glass tools need to know WHICH user's VM to target. Pass the
// user's email via --user <email> (or the IPAD_CLAUDE_USER env var); we look up
// their sub in the Cognito pool, then read the namespaced SSM params.
const { spawnSync } = require('child_process');

const PROFILE = process.env.AWS_PROFILE || 'default';
const REGION = process.env.AWS_REGION || 'us-east-1';
const STACK = process.env.STACK_NAME || 'ipad-claude';

function aws(...parts) {
  const r = spawnSync('aws', [...parts, '--profile', PROFILE, '--region', REGION, '--output', 'text'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr?.trim() || `aws ${parts[0]} failed`);
  return r.stdout.trim();
}

// Pull --user <email> from argv (or IPAD_CLAUDE_USER). Returns the email or null.
function userArg(argv) {
  const i = argv.indexOf('--user');
  if (i !== -1 && argv[i + 1]) return argv[i + 1];
  return process.env.IPAD_CLAUDE_USER || null;
}

function stackOutput(key) {
  return aws('cloudformation', 'describe-stacks', '--stack-name', STACK,
    '--query', `Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue`);
}

// Resolve { mvmId, endpoint } for the given user's email. Throws with a clear
// message if no user was passed or the user has no running VM yet.
function resolveMvm(email) {
  if (!email) {
    throw new Error(
      'No user specified. Per-user MicroVMs are keyed by Cognito user.\n'
      + '  Pass --user <email>, or set IPAD_CLAUDE_USER=<email>.\n'
      + '  (The user must have logged in at least once so their VM exists.)');
  }
  const poolId = stackOutput('UserPoolId');
  if (!poolId) throw new Error(`Could not read UserPoolId from stack '${STACK}'.`);

  const sub = aws('cognito-idp', 'admin-get-user', '--user-pool-id', poolId,
    '--username', email, '--query', 'UserAttributes[?Name==`sub`].Value | [0]');
  if (!sub || sub === 'None') throw new Error(`User '${email}' not found in pool ${poolId}.`);

  let mvmId, endpoint;
  try {
    mvmId = aws('ssm', 'get-parameter', '--name', `/ipad-claude/users/${sub}/mvm-identifier`, '--query', 'Parameter.Value');
    endpoint = aws('ssm', 'get-parameter', '--name', `/ipad-claude/users/${sub}/mvm-endpoint`, '--query', 'Parameter.Value');
  } catch (e) {
    throw new Error(`No MicroVM for '${email}' yet — they must sign in once to provision it.`);
  }
  return { mvmId, endpoint, sub };
}

module.exports = { aws, userArg, resolveMvm, PROFILE, REGION, STACK };
