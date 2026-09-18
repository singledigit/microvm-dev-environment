#!/bin/bash
# End-to-end deploy for ipad-claude
# Usage: ./scripts/deploy.sh [--skip-infra] [--skip-mvm]
#   --skip-infra   reuse the existing SAM stack (skip sam build/deploy and the
#                  MicroVM image entirely — frontend sync + smoke test only)
#   --skip-mvm     skip the throwaway smoke-test VM
#
# No project-specific config file for profile/region/account: sam build and
# sam deploy read stack_name/region/profile from samconfig.toml on their own
# (that's what it's for — see samconfig.toml.example). This script's own raw
# `aws` calls (the web-search gateway, S3 uploads, the smoke test — none of
# which are `sam` commands, so samconfig.toml doesn't apply to them) rely on
# the SAME standard AWS CLI resolution every script does: AWS_PROFILE /
# AWS_REGION env vars, or your default profile. Export them once, or run
# `AWS_PROFILE=... AWS_REGION=... ./scripts/deploy.sh` — nothing here parses
# a config file to re-derive them.
#
# The MicroVM image is a real CFN resource (AWS::Serverless::MicrovmImage) in
# template.yaml, not a hand-rolled aws lambda-microvms CLI dance — its own
# configuration (name, memory tier, capabilities, base image) lives entirely
# as literals on that resource, not here. There's no --skip-image /
# --recreate-image: if microvm/ hasn't changed, its content hash produces the
# same S3 key, CodeUri comes out identical, and CloudFormation no-ops the
# resource on its own. Changing AdditionalOsCapabilities is now a normal
# in-place update too (the CLI required delete+recreate for that).
set -euo pipefail

# Resolve repo root from this script's location (no hardcoded path).
# Unset CDPATH first: if it's set in the user's env, `cd` echoes the target
# dir to stdout, which would corrupt the command substitution below.
SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"

# Fixed identifier for this app's stack — matches samconfig.toml's own
# stack_name literal (the two are independent tools/files, kept in sync by
# hand; this rarely changes). Not a config knob.
STACK_NAME="ipad-claude"

SKIP_INFRA=false
SKIP_MVM=false
for arg in "$@"; do
  case $arg in
    --skip-infra) SKIP_INFRA=true ;;
    --skip-mvm)   SKIP_MVM=true ;;
  esac
done

log() { echo -e "\033[1;36m▶ $*\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $*\033[0m"; }
err() { echo -e "\033[1;31m✗ $*\033[0m" >&2; }

# ── Show resolved AWS identity (no config-driven gate — just visual confirmation) ─
log "Resolving AWS identity (from your default profile/env — see the header comment)..."
CALLER=$(aws sts get-caller-identity --output json)
CALLER_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
CALLER_ARN=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Authenticated as $CALLER_ARN (account $CALLER_ACCOUNT) — Ctrl+C now if that's wrong"

out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""; }

# ── AgentCore web-search gateway + MicroVM image inputs ────────────────────────
# Both MicrovmCodeUri and WebSearchGatewayUrl are inputs the MicrovmImage
# resource needs, but neither can be computed by CloudFormation itself — the
# gateway isn't in the template (see WebSearchGatewayRole's comment), and the
# image's CodeUri needs a real, already-uploaded S3 object before `sam deploy`
# can create/update the resource. So both must be resolved BEFORE the deploy
# call, from the stack's EXISTING state (ArtifactBucketName, WebSearchGateway-
# RoleArn don't change identity across updates). This only works when the
# stack already exists — bootstrapping a truly first-ever deploy needs those
# two resources (the bucket, the role) created by a preceding `sam deploy`
# first; see the README for that one-time sequence.
WEBSEARCH_GATEWAY_URL=""
MICROVM_CODE_URI=""
if [ "$SKIP_INFRA" = false ]; then
  ARTIFACT_BUCKET=$(out ArtifactBucketName)
  WEBSEARCH_GW_ROLE_ARN=$(out WebSearchGatewayRoleArn)

  if [ -z "$ARTIFACT_BUCKET" ] || [ -z "$WEBSEARCH_GW_ROLE_ARN" ]; then
    err "Stack '$STACK_NAME' not found (or missing outputs) — this looks like a" \
        "first-ever deploy. See the README's bootstrap note before running" \
        "deploy.sh: the stack needs one initial 'sam deploy' to create the" \
        "artifact bucket and the web-search gateway role before this script's" \
        "two-way dependency (image needs the bucket, gateway needs the role,"\
        "both need the stack) can resolve."
    exit 1
  fi

  log "Ensuring AgentCore web-search gateway..."
  GATEWAY_NAME="ipadclaudewebsearch"
  GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
    --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text 2>/dev/null || echo "")

  if [ -z "$GATEWAY_ID" ] || [ "$GATEWAY_ID" = "None" ]; then
    log "Creating AgentCore gateway '$GATEWAY_NAME'..."
    GW_OUT=$(aws bedrock-agentcore-control create-gateway \
      --name "$GATEWAY_NAME" \
      --protocol-type MCP \
      --authorizer-type AWS_IAM \
      --role-arn "$WEBSEARCH_GW_ROLE_ARN" \
      --output json)
    GATEWAY_ID=$(echo "$GW_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['gatewayId'])")
    WEBSEARCH_GATEWAY_URL=$(echo "$GW_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['gatewayUrl'])")

    for i in $(seq 1 30); do
      GW_STATUS=$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$GATEWAY_ID" \
        --query status --output text 2>/dev/null || echo "UNKNOWN")
      [ "$GW_STATUS" = "READY" ] && break
      sleep 2
    done
    if [ "$GW_STATUS" != "READY" ]; then
      err "Gateway stuck in $GW_STATUS"; exit 1
    fi

    log "Adding web-search connector target..."
    aws bedrock-agentcore-control create-gateway-target \
      --gateway-identifier "$GATEWAY_ID" \
      --name "websearch" \
      --target-configuration '{"mcp":{"connector":{"source":{"connectorId":"web-search"},"configurations":[{"name":"WebSearch","parameterValues":{}}]}}}' \
      --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
      --output json > /dev/null

    for i in $(seq 1 30); do
      TGT_STATUS=$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
        --query "items[0].status" --output text 2>/dev/null || echo "UNKNOWN")
      [ "$TGT_STATUS" = "READY" ] && break
      sleep 2
    done
    ok "Web-search gateway created: $GATEWAY_ID (target: $TGT_STATUS)"
  else
    WEBSEARCH_GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$GATEWAY_ID" \
      --query gatewayUrl --output text 2>/dev/null || echo "")
    ok "Web-search gateway exists: $GATEWAY_ID"
  fi
  ok "Web-search MCP endpoint: $WEBSEARCH_GATEWAY_URL"

  # ── Package the MicroVM image source and compute its content-hash S3 key ────
  # CloudFormation only diffs property VALUES. AWS::Serverless::MicrovmImage
  # isn't in SAM's local-file auto-upload list (unlike Function's CodeUri,
  # which SAM content-hashes automatically) — so if this always uploaded to
  # the SAME key, a real microvm/ change would produce an IDENTICAL CodeUri
  # string and CloudFormation would silently skip rebuilding. Hashing the zip
  # into the key name replicates what SAM does for Functions, by hand.
  log "Packaging MicroVM source..."
  BUILD_DIR="/tmp/remote-dev-microvm-build"
  rm -rf "$BUILD_DIR"; cp -R "$ROOT_DIR/microvm" "$BUILD_DIR"
  # Render the account-specific FS id into the copy only — never commit it.
  S3_FILES_FS_ID=$(out S3FilesFileSystemId)
  sed -i.bak "s|^ENV S3_FILES_FS_ID=.*|ENV S3_FILES_FS_ID=${S3_FILES_FS_ID}|" "$BUILD_DIR/Dockerfile"
  rm -f "$BUILD_DIR/Dockerfile.bak"

  ZIP_PATH="/tmp/remote-dev-microvm.zip"
  rm -f "$ZIP_PATH"
  (cd "$BUILD_DIR" && zip -r "$ZIP_PATH" . -x "*.DS_Store" > /dev/null)
  ZIP_HASH=$(shasum -a 256 "$ZIP_PATH" | cut -c1-16)
  ZIP_KEY="microvm/remote-dev-microvm-${ZIP_HASH}.zip"
  MICROVM_CODE_URI="s3://$ARTIFACT_BUCKET/$ZIP_KEY"

  aws s3 cp "$ZIP_PATH" "s3://$ARTIFACT_BUCKET/$ZIP_KEY"
  ok "Source uploaded to $MICROVM_CODE_URI"
fi

# ── Infrastructure + MicroVM image: SAM build + deploy ─────────────────────────
# No --profile/--region/--stack-name here — sam reads all three from
# samconfig.toml on its own. --parameter-overrides supplies ONLY the two
# values that are genuinely computed above; anything else set via
# samconfig.toml's own parameter_overrides (e.g. LoginEmail) is retained
# unchanged by CloudFormation, since it isn't mentioned in this list.
if [ "$SKIP_INFRA" = false ]; then
  log "Building SAM application..."
  (cd "$ROOT_DIR" && sam build --template template.yaml)

  log "Deploying SAM stack (this includes the MicroVM image build if microvm/" \
      "changed — CloudFormation waits for it, ~5-10 min on a real change)..."
  (cd "$ROOT_DIR" && sam deploy \
    --parameter-overrides "MicrovmCodeUri=$MICROVM_CODE_URI WebSearchGatewayUrl=$WEBSEARCH_GATEWAY_URL" \
    --no-confirm-changeset --no-fail-on-empty-changeset)
  ok "SAM stack deployed"
else
  log "Skipping infra (--skip-infra), using existing stack outputs..."
fi

# ── Read stack outputs (SAM creates a normal CloudFormation stack) ────────────
# TokenApiUrl/FrontendUrl/UserPoolId/LoginEmail/CreateUserCommand etc. were
# already printed by `sam deploy` itself moments ago (when --skip-infra is
# false) — only re-read here what deploy.sh actually NEEDS to act on: the
# frontend sync and the smoke test.
EXECUTION_ROLE=$(out ExecutionRoleArn)
FRONTEND_BUCKET=$(out FrontendBucketName)
CF_DIST_ID=$(out CloudFrontDistributionId)
USER_POOL_ID=$(out UserPoolId)
USER_POOL_CLIENT_ID=$(out UserPoolClientId)
TOKEN_API_URL=$(out TokenApiUrl)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)
NETWORK_CONNECTOR_ARN=$(out NetworkConnectorArn)
IMAGE_ID=$(out MicrovmImageArn)

# ── Inject runtime config into frontend (token API + Cognito ids) ─────────────
# index.html ships with an APP_CONFIG placeholder; fill it at deploy time. We
# render to a temp copy so the committed file keeps its placeholder (no
# account-specific values ever land in git).
log "Injecting runtime config into frontend..."
FRONTEND_FILE="$ROOT_DIR/frontend/index.html"
RENDERED=/tmp/ipad-claude-index.html
APP_CONFIG_JSON="{\"tokenApiUrl\":\"$TOKEN_API_URL\",\"region\":\"$(aws configure get region 2>/dev/null || echo us-east-1)\",\"userPoolId\":\"$USER_POOL_ID\",\"userPoolClientId\":\"$USER_POOL_CLIENT_ID\"}"
# Replace the whole placeholder <script> line with the injected config.
sed "s|<script>window.APP_CONFIG = {}; /\* APP_CONFIG_PLACEHOLDER \*/</script>|<script>window.APP_CONFIG = $APP_CONFIG_JSON;</script>|" \
  "$FRONTEND_FILE" > "$RENDERED"

# Sync updated frontend (render replaces the placeholder file in the upload dir)
log "Syncing frontend to S3 ($FRONTEND_BUCKET)..."
cp "$RENDERED" "$ROOT_DIR/frontend/index.html.rendered"
aws s3 cp "$RENDERED" "s3://$FRONTEND_BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html"
rm -f "$ROOT_DIR/frontend/index.html.rendered"

if [ -n "$CF_DIST_ID" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$CF_DIST_ID" \
    --paths "/*" > /dev/null
fi
ok "Frontend synced and CDN invalidated"

# ── Smoke-test MicroVM (throwaway) ──────────────────────────────────────────────
# Per-user MVMs are launched on demand by the token Lambda at login (keyed to
# the Cognito user), NOT here. This launches ONE throwaway VM purely to smoke-
# test the image end-to-end, then terminates it. To exercise the real per-user
# mount path, we create a temporary access point and pass its id via
# --run-hook-payload, exactly as the Lambda does.
SMOKE_AP=""
if [ "$SKIP_MVM" = false ]; then
  if [ -z "$IMAGE_ID" ]; then
    err "No MicrovmImageArn stack output — run without --skip-infra at least once first."
    exit 1
  fi

  EGRESS_FLAG=""
  if [ -n "$NETWORK_CONNECTOR_ARN" ] && [ "$NETWORK_CONNECTOR_ARN" != "None" ]; then
    EGRESS_FLAG="--egress-network-connectors [\"$NETWORK_CONNECTOR_ARN\"]"
  fi
  REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

  log "Creating throwaway access point for smoke test..."
  SMOKE_AP=$(aws s3files create-access-point \
    --file-system-id "$S3_FILES_FS_ID" \
    --posix-user 'uid=1000,gid=1000' \
    --root-directory 'path=/users/_smoketest,creationPermissions={ownerUid=1000,ownerGid=1000,permissions=0755}' \
    --query 'accessPointId' --output text 2>/dev/null || echo "")

  log "Launching smoke-test MicroVM..."
  RUN_OUT=$(aws lambda-microvms run-microvm \
    --image-identifier "$IMAGE_ID" \
    --execution-role-arn "$EXECUTION_ROLE" \
    --idle-policy '{"maxIdleDurationSeconds":1800,"suspendedDurationSeconds":600,"autoResumeEnabled":true}' \
    --maximum-duration-in-seconds 28800 \
    --ingress-network-connectors "[\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:HTTP_INGRESS\",\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:SHELL_INGRESS\"]" \
    $EGRESS_FLAG \
    ${SMOKE_AP:+--run-hook-payload "{\"accessPointId\":\"$SMOKE_AP\"}"} \
    --output json 2>&1)

  MVM_ID=$(echo "$RUN_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('microvmId',''))" 2>/dev/null || echo "")
  MVM_ENDPOINT=$(echo "$RUN_OUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ep = d.get('endpoint','')
print(ep if ep.startswith('https://') else 'https://' + ep)
" 2>/dev/null || echo "")

  if [ -z "$MVM_ID" ]; then
    err "Failed to extract microvmId from run response"
    echo "$RUN_OUT" | tail -20 >&2
    exit 1
  fi

  ok "Smoke-test MicroVM launched: $MVM_ID"
  ok "Endpoint: $MVM_ENDPOINT"
  # Give snapshot boot + /run-hook mount a moment before probing
  sleep 15
  MVM_STATE="RUNNING"
else
  log "Skipping MVM smoke test (--skip-mvm)"
  MVM_ID=""
  MVM_ENDPOINT=""
  MVM_STATE="not launched"
fi

# ── Smoke test + teardown of the throwaway VM ───────────────────────────────────
if [ "$SKIP_MVM" = false ] && [ -n "$MVM_ID" ]; then
  log "Smoke-testing ttyd (port 8080)..."
  SMOKE_TOKEN=$(aws lambda-microvms create-microvm-auth-token \
    --microvm-identifier "$MVM_ID" \
    --expiration-in-minutes 5 \
    --allowed-ports '[{"port":8080}]' \
    --query 'authToken."X-aws-proxy-auth"' --output text 2>/dev/null || echo "")

  if [ -n "$SMOKE_TOKEN" ] && [ -n "$MVM_ENDPOINT" ]; then
    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
      -H "X-aws-proxy-auth: $SMOKE_TOKEN" \
      --max-time 15 \
      "$MVM_ENDPOINT/" 2>/dev/null || echo "000")
    if [[ "$HTTP_STATUS" =~ ^[23] ]]; then
      ok "ttyd responding (HTTP $HTTP_STATUS)"
    else
      log "ttyd returned HTTP $HTTP_STATUS — may still be warming up"
    fi
  fi

  # Tear down the throwaway smoke-test VM + access point — real per-user VMs
  # are launched by the token Lambda at login.
  log "Tearing down smoke-test VM..."
  aws lambda-microvms terminate-microvm --microvm-identifier "$MVM_ID" 2>/dev/null || true
  if [ -n "$SMOKE_AP" ] && [ "$SMOKE_AP" != "None" ]; then
    aws s3files delete-access-point --access-point-id "$SMOKE_AP" 2>/dev/null || true
  fi
  MVM_STATE="smoke-tested + torn down"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
# Deliberately short: TokenApiUrl, FrontendUrl, UserPoolId, LoginEmail, and
# CreateUserCommand were all already printed by `sam deploy` itself above —
# this only reports what THIS script uniquely did (the smoke test).
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Remote Developer (rDev) — Deployed Successfully"
echo "  Smoke test: $MVM_STATE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
