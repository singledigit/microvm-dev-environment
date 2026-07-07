#!/bin/bash
# End-to-end deploy for ipad-claude
# Usage: ./scripts/deploy.sh [--skip-infra] [--skip-image] [--skip-mvm] [--recreate-image]
#   --skip-infra   reuse the existing SAM stack (skip sam build/deploy)
#   --skip-image   reuse the existing MicroVM image (skip the image build)
#   --skip-mvm     skip the throwaway smoke-test VM
#   --recreate-image  delete + recreate the image (needed to change OS capabilities)
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
STACK_NAME="${STACK_NAME:-ipad-claude}"

SKIP_INFRA=false
SKIP_IMAGE=false
SKIP_MVM=false
RECREATE_IMAGE=false
for arg in "$@"; do
  case $arg in
    --skip-infra)     SKIP_INFRA=true ;;
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

# Auth is Cognito now (no shared password). Users are admin-created in the pool;
# see the "create a user" command printed in the summary below.

# ── Infrastructure: SAM build + deploy ────────────────────────────────────────
if [ "$SKIP_INFRA" = false ]; then
  log "Building SAM application..."
  (cd "$ROOT_DIR" && sam build --template template.yaml)

  log "Deploying SAM stack '$STACK_NAME'..."
  (cd "$ROOT_DIR" && sam deploy \
    --stack-name "$STACK_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --parameter-overrides "ImageName=$IMAGE_NAME" \
    --no-confirm-changeset --no-fail-on-empty-changeset)
  ok "SAM stack deployed"
else
  log "Skipping infra (--skip-infra), using existing stack outputs..."
fi

# ── Read stack outputs (SAM creates a normal CloudFormation stack) ────────────
out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --profile "$PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

ARTIFACT_BUCKET=$(out ArtifactBucketName)
BUILD_ROLE=$(out BuildRoleArn)
EXECUTION_ROLE=$(out ExecutionRoleArn)
TOKEN_API_URL=$(out TokenApiUrl)
FRONTEND_URL=$(out FrontendUrl)
FRONTEND_BUCKET=$(out FrontendBucketName)
CF_DIST_ID=$(out CloudFrontDistributionId)
USER_POOL_ID=$(out UserPoolId)
USER_POOL_CLIENT_ID=$(out UserPoolClientId)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)
NETWORK_CONNECTOR_ARN=$(out NetworkConnectorArn)

ok "Artifact bucket : $ARTIFACT_BUCKET"
ok "Token API       : $TOKEN_API_URL"
ok "Frontend        : $FRONTEND_URL"

# ── Inject runtime config into frontend (token API + Cognito ids) ─────────────
# index.html ships with an APP_CONFIG placeholder; fill it at deploy time. We
# render to a temp copy so the committed file keeps its placeholder (no
# account-specific values ever land in git).
log "Injecting runtime config into frontend..."
FRONTEND_FILE="$ROOT_DIR/frontend/index.html"
RENDERED=/tmp/ipad-claude-index.html
APP_CONFIG_JSON="{\"tokenApiUrl\":\"$TOKEN_API_URL\",\"region\":\"$REGION\",\"userPoolId\":\"$USER_POOL_ID\",\"userPoolClientId\":\"$USER_POOL_CLIENT_ID\"}"
# Replace the whole placeholder <script> line with the injected config.
sed "s|<script>window.APP_CONFIG = {}; /\* APP_CONFIG_PLACEHOLDER \*/</script>|<script>window.APP_CONFIG = $APP_CONFIG_JSON;</script>|" \
  "$FRONTEND_FILE" > "$RENDERED"

# Sync updated frontend (render replaces the placeholder file in the upload dir)
log "Syncing frontend to S3 ($FRONTEND_BUCKET)..."
cp "$RENDERED" "$ROOT_DIR/frontend/index.html.rendered"
aws s3 cp "$RENDERED" "s3://$FRONTEND_BUCKET/index.html" --profile "$PROFILE"
rm -f "$ROOT_DIR/frontend/index.html.rendered"

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

# ── Smoke-test MicroVM (throwaway) ──────────────────────────────────────────────
# Per-user MVMs are launched on demand by the token Lambda at login (keyed to
# the Cognito user), NOT here. This launches ONE throwaway VM purely to smoke-
# test the freshly-built image end-to-end, then terminates it. To exercise the
# real per-user mount path, we create a temporary access point and pass its id
# via --run-hook-payload, exactly as the Lambda does.
SMOKE_AP=""
if [ "$SKIP_MVM" = false ]; then
  # Build egress connector flag
  EGRESS_FLAG=""
  if [ -n "$NETWORK_CONNECTOR_ARN" ] && [ "$NETWORK_CONNECTOR_ARN" != "None" ]; then
    EGRESS_FLAG="--egress-network-connectors [\"$NETWORK_CONNECTOR_ARN\"]"
  fi

  log "Creating throwaway access point for smoke test..."
  SMOKE_AP=$(aws s3files create-access-point \
    --file-system-id "$S3_FILES_FS_ID" \
    --posix-user 'uid=1000,gid=1000' \
    --root-directory 'path=/users/_smoketest,creationPermissions={ownerUid=1000,ownerGid=1000,permissions=0755}' \
    --profile "$PROFILE" --region "$REGION" \
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

  # Tear down the throwaway smoke-test VM + access point — real per-user VMs
  # are launched by the token Lambda at login.
  log "Tearing down smoke-test VM..."
  aws lambda-microvms terminate-microvm --microvm-identifier "$MVM_ID" \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
  if [ -n "$SMOKE_AP" ] && [ "$SMOKE_AP" != "None" ]; then
    aws s3files delete-access-point --access-point-id "$SMOKE_AP" \
      --profile "$PROFILE" --region "$REGION" 2>/dev/null || true
  fi
  MVM_STATE="smoke-tested + torn down"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  iPad Claude Code — Deployed Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Frontend URL : $FRONTEND_URL"
echo "  Token API    : $TOKEN_API_URL"
echo "  Smoke test   : $MVM_STATE"
echo "  User pool    : $USER_POOL_ID"
echo ""
echo "  Auth is Cognito (admin-created users, no self-signup)."
echo "  Create a user with a temporary password (they set a permanent one on"
echo "  first sign-in):"
echo ""
echo "    aws cognito-idp admin-create-user \\"
echo "      --user-pool-id $USER_POOL_ID \\"
echo "      --username ${LOGIN_EMAIL:-you@example.com} \\"
echo "      --user-attributes Name=email,Value=${LOGIN_EMAIL:-you@example.com} Name=email_verified,Value=true \\"
echo "      --temporary-password 'ChangeMe-123!' \\"
echo "      --profile $PROFILE --region $REGION"
echo ""
echo "  Then open $FRONTEND_URL and sign in with that email + temp password."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
