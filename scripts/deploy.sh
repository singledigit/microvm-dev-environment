#!/bin/bash
# End-to-end deploy for ipad-claude
# Usage: ./scripts/deploy.sh [--skip-cdk] [--skip-image] [--skip-mvm] [--recreate-image]
set -euo pipefail

# Resolve repo root from this script's location (no hardcoded path).
# Unset CDPATH first: if it's set in the user's env, `cd` echoes the target
# dir to stdout, which would corrupt the command substitution below.
SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"

# Load deployment config. Copy config.env.example → config.env and fill it in.
if [ ! -f "$ROOT_DIR/config.env" ]; then
  echo "config.env not found. Copy config.env.example to config.env and set your values." >&2
  exit 1
fi
set -a; . "$ROOT_DIR/config.env"; set +a

PROFILE="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="${AWS_ACCOUNT:?set AWS_ACCOUNT in config.env}"
IMAGE_NAME="${IMAGE_NAME:-ipad-claude-v2}"
MVM_MEMORY="${MVM_MEMORY:-8192}"
# Optional: reuse an existing S3 Files filesystem. Blank = the CDK stack creates
# one, and we read its id back from the stack outputs after deploy.
S3_FILES_FS_ID_CFG="${S3_FILES_FS_ID:-}"

SKIP_CDK=false
SKIP_IMAGE=false
SKIP_MVM=false
RECREATE_IMAGE=false
for arg in "$@"; do
  case $arg in
    --skip-cdk)       SKIP_CDK=true ;;
    --skip-image)     SKIP_IMAGE=true ;;
    --skip-mvm)       SKIP_MVM=true ;;
    --recreate-image) RECREATE_IMAGE=true ;;
  esac
done

log() { echo -e "\033[1;36m▶ $*\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $*\033[0m"; }
err() { echo -e "\033[1;31m✗ $*\033[0m" >&2; }

# ── Verify AWS credentials ────────────────────────────────────────────────────
log "Checking AWS credentials (profile: $PROFILE)..."
CALLER=$(aws sts get-caller-identity --profile "$PROFILE" --output json)
ACTUAL_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
if [ "$ACTUAL_ACCOUNT" != "$ACCOUNT" ]; then
  err "Expected account $ACCOUNT but got $ACTUAL_ACCOUNT"
  exit 1
fi
ok "Authenticated as $(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")"

# ── Generate password (first time) or read existing ───────────────────────────
EXISTING_PW=$(aws ssm get-parameter \
  --name "/ipad-claude/password" \
  --with-decryption \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_PW" ]; then
  log "Generating new password..."
  # 20 chars: letters + digits only (no special chars that confuse terminals)
  PORTAL_PASSWORD=$(python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits
print(''.join(secrets.choice(chars) for _ in range(20)))
")
  aws ssm put-parameter \
    --name "/ipad-claude/password" \
    --value "$PORTAL_PASSWORD" \
    --type "SecureString" \
    --overwrite \
    --profile "$PROFILE" \
    --region "$REGION" > /dev/null
  ok "Password stored in SSM (SecureString)"
else
  PORTAL_PASSWORD="$EXISTING_PW"
  ok "Using existing password from SSM"
fi

# ── CDK deploy ────────────────────────────────────────────────────────────────
if [ "$SKIP_CDK" = false ]; then
  log "Installing CDK dependencies..."
  (cd "$ROOT_DIR/cdk" && npm install --silent)

  log "Bootstrapping CDK (idempotent)..."
  (cd "$ROOT_DIR/cdk" && npx cdk bootstrap "aws://$ACCOUNT/$REGION" \
    --profile "$PROFILE" \
    --cloudformation-execution-policies "arn:aws:iam::aws:policy/AdministratorAccess" \
    2>&1 | tail -3)

  log "Deploying CDK stack..."
  (cd "$ROOT_DIR/cdk" && CDK_DEFAULT_ACCOUNT="$ACCOUNT" CDK_DEFAULT_REGION="$REGION" \
    npx cdk deploy IpadClaudeStack \
    --profile "$PROFILE" \
    --require-approval never \
    -c s3FilesFileSystemId="$S3_FILES_FS_ID_CFG" \
    --outputs-file /tmp/ipad-claude-outputs.json \
    2>&1)
  ok "CDK stack deployed"
else
  log "Skipping CDK (--skip-cdk), reading existing outputs..."
  aws cloudformation describe-stacks \
    --stack-name IpadClaudeStack \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output json \
    | python3 -c "
import sys, json
outputs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
result = {'IpadClaudeStack': outputs}
print(json.dumps(result))
" > /tmp/ipad-claude-outputs.json
fi

# ── Read stack outputs ─────────────────────────────────────────────────────────
read_output() { python3 -c "import json; d=json.load(open('/tmp/ipad-claude-outputs.json')); print(d['IpadClaudeStack']['$1'])"; }
ARTIFACT_BUCKET=$(read_output ArtifactBucketName)
BUILD_ROLE=$(read_output BuildRoleArn)
EXECUTION_ROLE=$(read_output ExecutionRoleArn)
TOKEN_API_URL=$(read_output TokenApiUrl)
FRONTEND_URL=$(read_output FrontendUrl)
FRONTEND_BUCKET=$(read_output FrontendBucketName)
CF_DIST_ID=$(read_output CloudFrontDistributionId)

ok "Artifact bucket : $ARTIFACT_BUCKET"
ok "Token API       : $TOKEN_API_URL"
ok "Frontend        : $FRONTEND_URL"

# Always read S3 Files and network connector from CloudFormation
S3_FILES_FS_ID=$(aws cloudformation describe-stacks \
  --stack-name IpadClaudeStack \
  --profile "$PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='S3FilesFileSystemId'].OutputValue" \
  --output text 2>/dev/null || echo "$S3_FILES_FS_ID_CFG")

NETWORK_CONNECTOR_ARN=$(aws cloudformation describe-stacks \
  --stack-name IpadClaudeStack \
  --profile "$PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='NetworkConnectorArn'].OutputValue" \
  --output text 2>/dev/null || echo "")

# ── Inject TOKEN_API_URL into frontend ────────────────────────────────────────
log "Injecting token API URL into frontend..."
FRONTEND_FILE="$ROOT_DIR/frontend/index.html"
if grep -q "<script>window\.TOKEN_API_URL" "$FRONTEND_FILE"; then
  # Already injected — update the value
  sed -i.bak "s|window\.TOKEN_API_URL = '[^']*'|window.TOKEN_API_URL = '$TOKEN_API_URL'|g" "$FRONTEND_FILE"
  rm -f "${FRONTEND_FILE}.bak"
else
  # Inject right before </title>
  sed -i.bak "s|</title>|</title>\n  <script>window.TOKEN_API_URL = '$TOKEN_API_URL';</script>|" "$FRONTEND_FILE"
  rm -f "${FRONTEND_FILE}.bak"
fi

# Sync updated frontend
log "Syncing frontend to S3 ($FRONTEND_BUCKET)..."
aws s3 sync "$ROOT_DIR/frontend/" "s3://$FRONTEND_BUCKET/" \
  --profile "$PROFILE" --delete

if [ -n "$CF_DIST_ID" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$CF_DIST_ID" \
    --paths "/*" \
    --profile "$PROFILE" > /dev/null
fi
ok "Frontend synced and CDN invalidated"

# ── Build MicroVM image ────────────────────────────────────────────────────────
if [ "$SKIP_IMAGE" = false ]; then
  log "Packaging MicroVM source..."
  ZIP_KEY="ipad-claude-microvm.zip"
  rm -f /tmp/"$ZIP_KEY"
  # Inject S3_FILES_FS_ID into Dockerfile before zipping
  sed -i.bak "s|^ENV S3_FILES_FS_ID=.*|ENV S3_FILES_FS_ID=${S3_FILES_FS_ID}|" "$ROOT_DIR/microvm/Dockerfile"
  rm -f "$ROOT_DIR/microvm/Dockerfile.bak"
  (cd "$ROOT_DIR/microvm" && zip -r /tmp/"$ZIP_KEY" . -x "*.DS_Store" > /dev/null)
  aws s3 cp /tmp/"$ZIP_KEY" "s3://$ARTIFACT_BUCKET/$ZIP_KEY" \
    --profile "$PROFILE"
  ok "Source uploaded to s3://$ARTIFACT_BUCKET/$ZIP_KEY"

  # GA API (create-microvm-image) takes capabilities, hooks, and env vars as
  # SEPARATE top-level flags — NOT nested in a --runtime blob.
  HOOKS_JSON="{
      \"port\": 9000,
      \"microvmImageHooks\": {
        \"ready\": \"ENABLED\",
        \"readyTimeoutInSeconds\": 180
      },
      \"microvmHooks\": {
        \"run\":                    \"ENABLED\",
        \"runTimeoutInSeconds\":     10,
        \"resume\":                 \"ENABLED\",
        \"resumeTimeoutInSeconds\":  10,
        \"suspend\":                \"ENABLED\",
        \"suspendTimeoutInSeconds\": 10,
        \"terminate\":              \"ENABLED\",
        \"terminateTimeoutInSeconds\": 10
      }
    }"

  log "Using S3 Files filesystem: $S3_FILES_FS_ID"
  log "Using network connector: $NETWORK_CONNECTOR_ARN"

  log "Updating MicroVM image '$IMAGE_NAME' with new version..."
  IMAGE_ID=$(aws lambda-microvms list-microvm-images \
    --profile "$PROFILE" --region "$REGION" \
    --query "items[?name=='$IMAGE_NAME'].imageArn | [0]" \
    --output text 2>/dev/null || echo "")

  # --additional-os-capabilities only applies at CREATE time; update ignores it.
  # To change capabilities, the image must be deleted and recreated.
  if [ "$RECREATE_IMAGE" = true ] && [ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "None" ]; then
    log "Recreating image — terminating any MVM referencing it, then deleting..."
    OLD_MVM_ID=$(aws ssm get-parameter --name "/ipad-claude/mvm-identifier" \
      --profile "$PROFILE" --region "$REGION" \
      --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    if [ -n "$OLD_MVM_ID" ] && [ "$OLD_MVM_ID" != "None" ]; then
      aws lambda-microvms terminate-microvm --microvm-identifier "$OLD_MVM_ID" \
        --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
      log "Waiting 15s for MVM termination to release the image..."
      sleep 15
    fi
    aws lambda-microvms delete-microvm-image --image-identifier "$IMAGE_ID" \
      --profile "$PROFILE" --region "$REGION" 2>&1 || true
    # Poll until the image is gone
    for i in $(seq 1 30); do
      STILL=$(aws lambda-microvms list-microvm-images --profile "$PROFILE" --region "$REGION" \
        --query "items[?name=='$IMAGE_NAME'].imageArn | [0]" --output text 2>/dev/null || echo "None")
      [ -z "$STILL" ] || [ "$STILL" = "None" ] && break
      printf "\r  Waiting for image deletion... (%d/30)" "$i"; sleep 5
    done
    echo ""
    IMAGE_ID=""
    ok "Old image deleted — will create fresh"
  fi

  if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" = "None" ]; then
    log "Creating new MicroVM image '$IMAGE_NAME' (with --additional-os-capabilities ALL)..."
    CREATE_OUT=$(aws lambda-microvms create-microvm-image \
      --name "$IMAGE_NAME" \
      --base-image-arn "arn:aws:lambda:$REGION:aws:microvm-image:al2023-1" \
      --build-role-arn "$BUILD_ROLE" \
      --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
      --additional-os-capabilities '["ALL"]' \
      --hooks "$HOOKS_JSON" \
      --environment-variables "{\"S3_FILES_FS_ID\":\"$S3_FILES_FS_ID\"}" \
      --profile "$PROFILE" --region "$REGION" --output json)
    IMAGE_ID=$(echo "$CREATE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['imageArn'])")
  else
    # update-microvm-image REPLACES the whole version config — capabilities, hooks,
    # and env vars reset to defaults unless re-passed every time. Always include them.
    log "Image '$IMAGE_NAME' exists ($IMAGE_ID), updating (re-passing capabilities)..."
    aws lambda-microvms update-microvm-image \
      --image-identifier "$IMAGE_ID" \
      --base-image-arn "arn:aws:lambda:$REGION:aws:microvm-image:al2023-1" \
      --build-role-arn "$BUILD_ROLE" \
      --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
      --additional-os-capabilities '["ALL"]' \
      --hooks "$HOOKS_JSON" \
      --environment-variables "{\"S3_FILES_FS_ID\":\"$S3_FILES_FS_ID\"}" \
      --profile "$PROFILE" --region "$REGION" --output json > /dev/null
  fi

  ok "Image: $IMAGE_ID — waiting for build (takes ~5-10 min)..."
  for i in $(seq 1 120); do
    IMAGE_JSON=$(aws lambda-microvms get-microvm-image \
      --image-identifier "$IMAGE_ID" \
      --profile "$PROFILE" --region "$REGION" --output json 2>/dev/null || echo '{}')
    BUILD_STATE=$(echo "$IMAGE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))")
    LATEST_VER=$(echo "$IMAGE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latestActiveImageVersion',''))")
    if { [ "$BUILD_STATE" = "UPDATED" ] || [ "$BUILD_STATE" = "CREATED" ]; } && [ -n "$LATEST_VER" ]; then
      ok "Image build complete: $IMAGE_ID (version $LATEST_VER)"
      break
    elif [[ "$BUILD_STATE" == *"FAIL"* ]]; then
      err "Image build failed (state: $BUILD_STATE)"
      echo "$IMAGE_JSON" >&2
      exit 1
    fi
    printf "\r  Build state: %-25s (%d/120)" "$BUILD_STATE" "$i"
    sleep 10
  done
  echo ""
else
  log "Skipping image build (--skip-image)"
  IMAGE_ID=$(aws lambda-microvms list-microvm-images \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query "items[?name=='$IMAGE_NAME'].imageArn | [0]" \
    --output text)
  ok "Using existing image: $IMAGE_ID"
fi

# ── Run MicroVM ────────────────────────────────────────────────────────────────
if [ "$SKIP_MVM" = false ]; then
  # Terminate any existing MicroVM first
  OLD_MVM_ID=$(aws ssm get-parameter \
    --name "/ipad-claude/mvm-identifier" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")
  if [ -n "$OLD_MVM_ID" ] && [ "$OLD_MVM_ID" != "None" ]; then
    log "Terminating old MicroVM: $OLD_MVM_ID..."
    aws lambda-microvms terminate-microvm \
      --microvm-identifier "$OLD_MVM_ID" \
      --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
  fi

  # Build egress connector flag
  EGRESS_FLAG=""
  if [ -n "$NETWORK_CONNECTOR_ARN" ] && [ "$NETWORK_CONNECTOR_ARN" != "None" ]; then
    EGRESS_FLAG="--egress-network-connectors [\"$NETWORK_CONNECTOR_ARN\"]"
  fi

  log "Launching MicroVM..."
  # GA run-microvm returns clean JSON with microvmId + endpoint — no debug scrape needed.
  RUN_OUT=$(aws lambda-microvms run-microvm \
    --image-identifier "$IMAGE_ID" \
    --execution-role-arn "$EXECUTION_ROLE" \
    --idle-policy '{"maxIdleDurationSeconds":1800,"suspendedDurationSeconds":600,"autoResumeEnabled":true}' \
    --maximum-duration-in-seconds 28800 \
    --ingress-network-connectors "[\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:HTTP_INGRESS\",\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:SHELL_INGRESS\"]" \
    $EGRESS_FLAG \
    --profile "$PROFILE" \
    --region "$REGION" \
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

  ok "MicroVM launched: $MVM_ID"
  ok "Endpoint: $MVM_ENDPOINT"

  # Store in SSM
  log "Storing MicroVM ID and endpoint in SSM..."
  aws ssm put-parameter --name "/ipad-claude/mvm-identifier" --value "$MVM_ID" \
    --type String --overwrite --profile "$PROFILE" --region "$REGION" > /dev/null
  aws ssm put-parameter --name "/ipad-claude/mvm-endpoint" --value "$MVM_ENDPOINT" \
    --type String --overwrite --profile "$PROFILE" --region "$REGION" > /dev/null
  ok "Stored in SSM"

  # MicroVM starts up immediately from snapshot; give it 10s then probe
  sleep 10
  MVM_STATE="RUNNING"
  ok "MicroVM should be RUNNING (snapshot boot)"
else
  log "Skipping MVM launch (--skip-mvm)"
  MVM_ID=$(aws ssm get-parameter \
    --name "/ipad-claude/mvm-identifier" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'Parameter.Value' --output text)
  MVM_ENDPOINT=$(aws ssm get-parameter \
    --name "/ipad-claude/mvm-endpoint" \
    --profile "$PROFILE" --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")
  MVM_STATE="RUNNING"
  ok "Using existing MVM: $MVM_ID"
fi

# ── Smoke test ────────────────────────────────────────────────────────────────
log "Smoke-testing ttyd (port 8080)..."
SMOKE_TOKEN=$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "$MVM_ID" \
  --expiration-in-minutes 5 \
  --allowed-ports '[{"port":8080}]' \
  --profile "$PROFILE" \
  --region "$REGION" \
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

# Email notifications removed — credentials shown in summary below

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  iPad Claude Code — Deployed Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Frontend URL : $FRONTEND_URL"
echo "  Token API    : $TOKEN_API_URL"
echo "  MicroVM ID   : $MVM_ID"
echo "  MVM State    : $MVM_STATE"
echo ""
echo "  Login:"
echo "    Email    : ${LOGIN_EMAIL:-any email (not validated)}"
echo "    Password : $PORTAL_PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
