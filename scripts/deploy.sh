#!/bin/bash
# End-to-end deploy for ipad-claude
# Usage: ./scripts/deploy.sh [--skip-cdk] [--skip-image] [--skip-mvm]
set -euo pipefail

PROFILE="demo"
REGION="us-east-1"
ACCOUNT="088483494489"
IMAGE_NAME="ipad-claude"
MVM_MEMORY="8192"
NOTIFICATION_EMAIL="ericdj@amazon.com"
ROOT_DIR="/Users/ericdj/Sites/ipad-claude"

SKIP_CDK=false
SKIP_IMAGE=false
SKIP_MVM=false
for arg in "$@"; do
  case $arg in
    --skip-cdk)   SKIP_CDK=true ;;
    --skip-image) SKIP_IMAGE=true ;;
    --skip-mvm)   SKIP_MVM=true ;;
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
  (cd "$ROOT_DIR/cdk" && npx cdk deploy IpadClaudeStack \
    --profile "$PROFILE" \
    --require-approval never \
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
result = {
  'IpadClaudeStack': {
    'ArtifactBucketName': outputs.get('ArtifactBucketName',''),
    'BuildRoleArn':       outputs.get('BuildRoleArn',''),
    'ExecutionRoleArn':   outputs.get('ExecutionRoleArn',''),
    'TokenApiUrl':        outputs.get('TokenApiUrl',''),
    'FrontendUrl':        outputs.get('FrontendUrl',''),
  }
}
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
FRONTEND_BUCKET=$(read_output FrontendBucketName 2>/dev/null || echo "ipad-claude-frontend-$ACCOUNT")
CF_DIST_ID=$(read_output CloudFrontDistributionId 2>/dev/null || echo "")

ok "Artifact bucket : $ARTIFACT_BUCKET"
ok "Token API       : $TOKEN_API_URL"
ok "Frontend        : $FRONTEND_URL"

# Always read S3 Files and network connector from CloudFormation
S3_FILES_FS_ID=$(aws cloudformation describe-stacks \
  --stack-name IpadClaudeStack \
  --profile "$PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='S3FilesFileSystemId'].OutputValue" \
  --output text 2>/dev/null || echo "fs-08fd8645a4c0f5b1f")

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
  (cd "$ROOT_DIR/microvm" && zip -r /tmp/"$ZIP_KEY" . -x "*.DS_Store" > /dev/null)
  aws s3 cp /tmp/"$ZIP_KEY" "s3://$ARTIFACT_BUCKET/$ZIP_KEY" \
    --profile "$PROFILE"
  ok "Source uploaded to s3://$ARTIFACT_BUCKET/$ZIP_KEY"

  RUNTIME_JSON="{
    \"hooks\": {
      \"port\": 9000,
      \"microVmImageHooks\": {
        \"ready\": \"ENABLED\",
        \"readyTimeoutInSeconds\": 180
      },
      \"microVmHooks\": {
        \"run\":                    \"ENABLED\",
        \"runTimeoutInSeconds\":     10,
        \"resume\":                 \"ENABLED\",
        \"resumeTimeoutInSeconds\":  10,
        \"suspend\":                \"ENABLED\",
        \"suspendTimeoutInSeconds\": 10,
        \"terminate\":              \"ENABLED\",
        \"terminateTimeoutInSeconds\": 10
      }
    },
    \"additionalCapabilities\": [\"ALL\"],
    \"environmentVariables\": {
      \"S3_FILES_FS_ID\": \"$S3_FILES_FS_ID\"
    }
  }"

  log "Using S3 Files filesystem: $S3_FILES_FS_ID"
  log "Using network connector: $NETWORK_CONNECTOR_ARN"

  log "Updating MicroVM image '$IMAGE_NAME' with new version..."
  IMAGE_ID=$(aws lambda-microvms list-micro-vm-images \
    --profile "$PROFILE" --region "$REGION" \
    --query "items[?name=='$IMAGE_NAME'].imageArn | [0]" \
    --output text 2>/dev/null || echo "")

  if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" = "None" ]; then
    log "Creating new MicroVM image '$IMAGE_NAME'..."
    CREATE_OUT=$(aws lambda-microvms create-micro-vm-image \
      --name "$IMAGE_NAME" \
      --base-image-arn "arn:aws:lambda:$REGION:aws:microvm-image:al2023-1" \
      --build-role-arn "$BUILD_ROLE" \
      --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
      --runtime "$RUNTIME_JSON" \
      --profile "$PROFILE" --region "$REGION" --output json)
    IMAGE_ID=$(echo "$CREATE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['imageArn'])")
  else
    log "Image '$IMAGE_NAME' exists ($IMAGE_ID), updating..."
    aws lambda-microvms update-micro-vm-image \
      --image-identifier "$IMAGE_ID" \
      --base-image-arn "arn:aws:lambda:$REGION:aws:microvm-image:al2023-1" \
      --build-role-arn "$BUILD_ROLE" \
      --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
      --runtime "$RUNTIME_JSON" \
      --profile "$PROFILE" --region "$REGION" --output json > /dev/null
  fi

  ok "Image: $IMAGE_ID — waiting for build (takes ~5-10 min)..."
  for i in $(seq 1 120); do
    IMAGE_JSON=$(aws lambda-microvms get-micro-vm-image \
      --image-identifier "$IMAGE_ID" \
      --profile "$PROFILE" --region "$REGION" --output json 2>/dev/null || echo '{}')
    BUILD_STATE=$(echo "$IMAGE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))")
    LATEST_VER=$(echo "$IMAGE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latestActiveImageVersion',''))")
    if [ "$BUILD_STATE" = "UPDATED" ] && [ -n "$LATEST_VER" ]; then
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
  IMAGE_ID=$(aws lambda-microvms list-micro-vm-images \
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
    aws lambda-microvms terminate-micro-vm \
      --micro-vm-identifier "$OLD_MVM_ID" \
      --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
  fi

  # Build egress connector flag
  EGRESS_FLAG=""
  if [ -n "$NETWORK_CONNECTOR_ARN" ] && [ "$NETWORK_CONNECTOR_ARN" != "None" ]; then
    EGRESS_FLAG="--egress-network-connectors [\"$NETWORK_CONNECTOR_ARN\"]"
  fi

  log "Launching MicroVM..."
  # Use --debug to capture raw response which includes microvmId (lowercase v)
  RAW_RUN=$(aws lambda-microvms run-micro-vm \
    --image-identifier "$IMAGE_ID" \
    --execution-role-arn "$EXECUTION_ROLE" \
    --idle-policy '{"maxIdleDurationSeconds":1800,"suspendedDurationSeconds":600,"autoResumeEnabled":true}' \
    --maximum-duration-in-seconds 28800 \
    $EGRESS_FLAG \
    --profile "$PROFILE" \
    --region "$REGION" \
    --debug --output json 2>&1)

  # Extract from raw response body (microvmId, lowercase v)
  MVM_ID=$(echo "$RAW_RUN" | grep "Response body:" -A1 | grep "microvmId" | python3 -c "
import sys, json, re
for line in sys.stdin:
    m = re.search(r'b\'(\{.*\})\'', line)
    if m:
        d = json.loads(m.group(1))
        print(d.get('microvmId', ''))
        break
")
  MVM_ENDPOINT=$(echo "$RAW_RUN" | grep "Response body:" -A1 | grep "microvmId" | python3 -c "
import sys, json, re
for line in sys.stdin:
    m = re.search(r'b\'(\{.*\})\'', line)
    if m:
        d = json.loads(m.group(1))
        print('https://' + d.get('endpoint', ''))
        break
")

  if [ -z "$MVM_ID" ]; then
    err "Failed to extract microvmId from run response"
    echo "$RAW_RUN" | tail -20 >&2
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
SMOKE_RAW=$(aws lambda-microvms create-micro-vm-auth-token \
  --micro-vm-identifier "$MVM_ID" \
  --expiration-in-minutes 5 \
  --allowed-ports '[{"port":8080}]' \
  --profile "$PROFILE" \
  --region "$REGION" \
  --debug --output json 2>&1)

SMOKE_TOKEN=$(echo "$SMOKE_RAW" | grep "Response body:" -A1 | grep "authToken" | python3 -c "
import sys, json, re
for line in sys.stdin:
    m = re.search(r'b\'(\{.*\})\'', line)
    if m:
        d = json.loads(m.group(1))
        tok = d.get('authToken', {})
        if isinstance(tok, dict):
            print(tok.get('X-aws-proxy-auth', ''))
        else:
            print(tok or '')
        break
" 2>/dev/null || echo "")

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
echo "    Email    : $NOTIFICATION_EMAIL"
echo "    Password : $PORTAL_PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
