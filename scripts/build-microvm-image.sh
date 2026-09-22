#!/bin/bash
# Build (or update) the production MicroVM image using the AWS CLI directly.
#
# This is a convenience wrapper around README Steps 2-4 ("Create the
# AgentCore web-search gateway" / "Package and upload the MicroVM source" /
# "Create (or update) the MicroVM image") — the README shows and explains
# every command this script runs, including why the image and gateway are
# plain aws lambda-microvms / bedrock-agentcore-control CLI calls rather
# than CloudFormation/SAM resources, and why update-microvm-image must
# always receive every property (it REPLACES the whole version config, not
# merges it). Read the README first; this script exists only to save
# retyping the same commands on repeat builds.
#
# Run this AFTER `sam deploy` has created the stack (README Step 1) — it
# reads ArtifactBucketName, BuildRoleArn, and S3FilesFileSystemId from the
# stack's own outputs. Re-run it any time microvm/ changes; it detects
# whether the image already exists and creates or updates accordingly.
#
# Usage: ./scripts/build-microvm-image.sh
#   WEBSEARCH_REGION=<region>   override where the web-search gateway lives
#                                (default us-east-1 — see README Step 2)
set -euo pipefail

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"

# Matches samconfig.toml's own stack_name literal — see deploy.sh's header.
STACK_NAME="remote-developer"
IMAGE_NAME="remote-dev"

log() { echo -e "\033[1;36m▶ $*\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $*\033[0m"; }
err() { echo -e "\033[1;31m✗ $*\033[0m" >&2; }

out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""; }

log "Reading stack outputs from '$STACK_NAME'..."
ARTIFACT_BUCKET=$(out ArtifactBucketName)
BUILD_ROLE=$(out BuildRoleArn)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)
WEBSEARCH_GW_ROLE_ARN=$(out WebSearchGatewayRoleArn)

if [ -z "$ARTIFACT_BUCKET" ] || [ -z "$BUILD_ROLE" ] || [ -z "$S3_FILES_FS_ID" ]; then
  err "Stack '$STACK_NAME' not found, or missing expected outputs." \
      "Run 'sam deploy' first (see the README's Stage 1) — this script builds" \
      "the image AFTER the stack exists, not before."
  exit 1
fi

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

# ── AgentCore web-search gateway ────────────────────────────────────────────
# Not a CFN resource — the resource handler has a serialization bug with
# the connector's empty ParameterValues map that causes CREATE_FAILED — so
# this is created out-of-band too, same reasoning as the image itself.
#
# Deliberately created in WEBSEARCH_REGION, NOT the stack's own $REGION: the
# AgentCore web-search CONNECTOR (not the Gateway service itself, which is
# broadly available) is only enabled per-account in specific regions today —
# confirmed empirically by testing the exact same create-gateway-target call
# in us-east-2 and us-west-2 for this account, both rejected with
# "Connector integration web-search is not available for this account",
# while the identical call succeeds in us-east-1. This is independent of
# where the rest of the stack (VPC, Cognito, the MicroVM image) deploys —
# IAM roles are global, so WebSearchGatewayRole (created by the SAM stack in
# whatever region you chose) can be assumed by a Gateway that lives
# elsewhere. Override WEBSEARCH_REGION yourself if AWS enables the connector
# in your stack's own region and you'd rather keep everything colocated.
WEBSEARCH_REGION="${WEBSEARCH_REGION:-us-east-1}"
log "Ensuring AgentCore web-search gateway (in $WEBSEARCH_REGION)..."
GATEWAY_NAME="${STACK_NAME//-/}websearch"
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$WEBSEARCH_REGION" \
  --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text 2>/dev/null || echo "")

if [ -z "$GATEWAY_ID" ] || [ "$GATEWAY_ID" = "None" ]; then
  log "Creating AgentCore gateway '$GATEWAY_NAME'..."
  GW_OUT=$(aws bedrock-agentcore-control create-gateway --region "$WEBSEARCH_REGION" \
    --name "$GATEWAY_NAME" \
    --protocol-type MCP \
    --authorizer-type AWS_IAM \
    --role-arn "$WEBSEARCH_GW_ROLE_ARN" \
    --output json)
  GATEWAY_ID=$(echo "$GW_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['gatewayId'])")
  WEBSEARCH_GATEWAY_URL=$(echo "$GW_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['gatewayUrl'])")

  for i in $(seq 1 30); do
    GW_STATUS=$(aws bedrock-agentcore-control get-gateway --region "$WEBSEARCH_REGION" --gateway-identifier "$GATEWAY_ID" \
      --query status --output text 2>/dev/null || echo "UNKNOWN")
    [ "$GW_STATUS" = "READY" ] && break
    sleep 2
  done
  if [ "$GW_STATUS" != "READY" ]; then
    err "Gateway stuck in $GW_STATUS"; exit 1
  fi

  log "Adding web-search connector target..."
  aws bedrock-agentcore-control create-gateway-target --region "$WEBSEARCH_REGION" \
    --gateway-identifier "$GATEWAY_ID" \
    --name "websearch" \
    --target-configuration '{"mcp":{"connector":{"source":{"connectorId":"web-search"},"configurations":[{"name":"WebSearch","parameterValues":{}}]}}}' \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --output json > /dev/null

  for i in $(seq 1 30); do
    TGT_STATUS=$(aws bedrock-agentcore-control list-gateway-targets --region "$WEBSEARCH_REGION" --gateway-identifier "$GATEWAY_ID" \
      --query "items[0].status" --output text 2>/dev/null || echo "UNKNOWN")
    [ "$TGT_STATUS" = "READY" ] && break
    sleep 2
  done
  ok "Web-search gateway created: $GATEWAY_ID (target: $TGT_STATUS)"
else
  WEBSEARCH_GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway --region "$WEBSEARCH_REGION" --gateway-identifier "$GATEWAY_ID" \
    --query gatewayUrl --output text 2>/dev/null || echo "")
  ok "Web-search gateway exists: $GATEWAY_ID"
fi
ok "Web-search MCP endpoint: $WEBSEARCH_GATEWAY_URL"

# ── Package the MicroVM image source ────────────────────────────────────────
# Render this account's S3 Files filesystem id, this stack's actual deploy
# region, and the web-search gateway's actual region into a COPY of the
# Dockerfile only — never commit any of them. DEPLOY_REGION and
# WEBSEARCH_REGION are deliberately separate: DEPLOY_REGION is where THIS
# STACK lives (used for the get-microvm self-lookup in hooks.js), while
# WEBSEARCH_REGION is where the gateway above actually lives (used only for
# the web-search MCP proxy's SigV4 signing) — they're the same value on a
# default deploy, but diverge whenever WEBSEARCH_REGION is pinned
# independently of where you deploy the rest of the stack (see this
# script's comment on the gateway section, above). Neither touches the
# image's separate, fixed AWS_REGION=us-east-1 used for Bedrock model calls
# — see the Dockerfile's own comment on that distinction.
log "Packaging MicroVM source..."
BUILD_DIR="/tmp/remote-developer-microvm-build"
rm -rf "$BUILD_DIR"; cp -R "$ROOT_DIR/microvm" "$BUILD_DIR"
sed -i.bak "s|^ENV S3_FILES_FS_ID=.*|ENV S3_FILES_FS_ID=${S3_FILES_FS_ID}|" "$BUILD_DIR/Dockerfile"
sed -i.bak "s|^ENV DEPLOY_REGION=.*|ENV DEPLOY_REGION=${REGION}|" "$BUILD_DIR/Dockerfile"
sed -i.bak "s|^ENV WEBSEARCH_REGION=.*|ENV WEBSEARCH_REGION=${WEBSEARCH_REGION}|" "$BUILD_DIR/Dockerfile"
rm -f "$BUILD_DIR/Dockerfile.bak"

# A fixed zip key is fine here (unlike the old CFN-resource approach, which
# needed a content hash to make CloudFormation notice a real change): this
# script decides create-vs-update by directly checking whether the image
# exists, not by diffing the S3 key, and update-microvm-image always re-runs
# unconditionally below.
ZIP_KEY="microvm/${IMAGE_NAME}.zip"
ZIP_PATH="/tmp/${IMAGE_NAME}.zip"
rm -f "$ZIP_PATH"
(cd "$BUILD_DIR" && zip -r "$ZIP_PATH" . -x "*.DS_Store" > /dev/null)
aws s3 cp "$ZIP_PATH" "s3://$ARTIFACT_BUCKET/$ZIP_KEY"
ok "Source uploaded to s3://$ARTIFACT_BUCKET/$ZIP_KEY"

# ── Create or update the image ──────────────────────────────────────────────
# This JSON literal is the full, exact configuration of the image: base
# image, memory tier, OS capabilities, egress, and lifecycle hooks. Every
# create-microvm-image AND update-microvm-image call below passes ALL of it,
# every time — update-microvm-image replaces the whole version config on
# each call, so a partial flag set silently resets whatever you omit
# (capabilities, hooks, env vars) back to defaults. Keeping every property
# in one place here, always passed in full, is what avoids that footgun.
#
# MinimumMemoryInMiB is a fixed-tier picker, not a free-form value — Lambda
# MicroVMs bill continuously at this baseline while running and auto-burst
# up to 4x it under load (billed per-second, only while actually bursting):
# 512→2048 peak, 1024→4096 peak, 2048→8192 peak, 4096→16384 peak,
# 8192→32768 peak. 4096 (4 GB baseline / 16 GB peak, 2 vCPU baseline / 8
# vCPU peak) gives headroom for sustained Claude Code / build workloads
# without paying the 8192 tier's continuous rate for capacity mostly needed
# only in bursts. Change this literal directly to move tiers.
HOOKS_JSON='{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":180,"validate":"ENABLED","validateTimeoutInSeconds":300},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":10,"resume":"ENABLED","resumeTimeoutInSeconds":10,"suspend":"ENABLED","suspendTimeoutInSeconds":10,"terminate":"ENABLED","terminateTimeoutInSeconds":10}}'
RESOURCES_JSON='[{"minimumMemoryInMiB":4096}]'
ENV_VARS_JSON=$(python3 -c "import json,sys; print(json.dumps({'S3_FILES_FS_ID': sys.argv[1], 'WEBSEARCH_GATEWAY_URL': sys.argv[2]}))" "$S3_FILES_FS_ID" "$WEBSEARCH_GATEWAY_URL")

IMAGE_ARN=$(aws lambda-microvms list-microvm-images \
  --query "items[?name=='$IMAGE_NAME'].imageArn | [0]" --output text 2>/dev/null || echo "")

if [ -z "$IMAGE_ARN" ] || [ "$IMAGE_ARN" = "None" ]; then
  log "Creating MicroVM image '$IMAGE_NAME' (first build; ~5-10 min)..."
  IMAGE_ARN=$(aws lambda-microvms create-microvm-image \
    --name "$IMAGE_NAME" \
    --base-image-arn "arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1" \
    --base-image-version "1" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
    --additional-os-capabilities '["ALL"]' \
    --resources "$RESOURCES_JSON" \
    --egress-network-connectors "[\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS\"]" \
    --hooks "$HOOKS_JSON" \
    --environment-variables "$ENV_VARS_JSON" \
    --query imageArn --output text)
else
  log "Updating MicroVM image '$IMAGE_NAME' ($IMAGE_ARN)..."
  aws lambda-microvms update-microvm-image \
    --image-identifier "$IMAGE_ARN" \
    --base-image-arn "arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1" \
    --base-image-version "1" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
    --additional-os-capabilities '["ALL"]' \
    --resources "$RESOURCES_JSON" \
    --egress-network-connectors "[\"arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS\"]" \
    --hooks "$HOOKS_JSON" \
    --environment-variables "$ENV_VARS_JSON" \
    --output json > /dev/null
fi

# ── Wait for the build to finish ────────────────────────────────────────────
# No CloudFormation stabilization wait to time out here — just poll for as
# long as the build actually takes. Success needs BOTH a terminal state
# (CREATED or UPDATED) AND a non-empty latestActiveImageVersion; field
# ordering matters, since state can flip before the version is populated.
log "Waiting for image build to finish (this can take 5-10 minutes)..."
for i in $(seq 1 120); do
  J=$(aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" \
    --output json 2>/dev/null || echo '{}')
  STATE=$(echo "$J" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))")
  VER=$(echo "$J" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latestActiveImageVersion',''))")
  if { [ "$STATE" = "UPDATED" ] || [ "$STATE" = "CREATED" ]; } && [ -n "$VER" ]; then
    ok "Image ready: $IMAGE_ARN (version $VER)"
    break
  elif [[ "$STATE" == *"FAIL"* ]]; then
    err "Image build FAILED: $STATE"
    echo "$J" >&2
    exit 1
  fi
  printf "\r  state: %-25s (%d/120)" "$STATE" "$i"
  sleep 10
done
echo ""

# ── Publish the image ARN for the token Lambda to read ─────────────────────
# TokenFunction never gets IMAGE_ARN as an env var (see template.yaml's
# comment on TokenFunction) — it reads this SSM parameter fresh on every
# invocation instead, so rebuilding the image never requires a redeploy.
log "Writing image ARN to SSM (/remote-developer/image-arn)..."
aws ssm put-parameter --name /remote-developer/image-arn --type String --overwrite --value "$IMAGE_ARN" > /dev/null
ok "Done. Image ARN: $IMAGE_ARN"
