#!/bin/bash
# Convenience wrapper around README Step 5 ("Smoke test (optional)") — see
# the README for what this does and why. Launches one throwaway MicroVM
# from the built image, confirms the terminal server responds, then tears
# it down. Nothing here is required for the app to work — per-user
# MicroVMs are launched on demand by the token Lambda at login, not by this
# script.
#
# Run this AFTER scripts/build-microvm-image.sh (or README Steps 2-4) has
# published the image ARN.
#
# Usage: ./scripts/smoke-test-vm.sh
set -euo pipefail

STACK_NAME="remote-developer"

log() { echo -e "\033[1;36m▶ $*\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $*\033[0m"; }
err() { echo -e "\033[1;31m✗ $*\033[0m" >&2; }

out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || echo ""; }

IMAGE_ARN=$(aws ssm get-parameter --name /remote-developer/image-arn --query Parameter.Value --output text 2>/dev/null || echo "")
if [ -z "$IMAGE_ARN" ] || [ "$IMAGE_ARN" = "None" ]; then
  err "No image ARN at /remote-developer/image-arn — run scripts/build-microvm-image.sh first."
  exit 1
fi

EXECUTION_ROLE=$(out ExecutionRoleArn)
NETWORK_CONNECTOR_ARN=$(out NetworkConnectorArn)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)
if [ -z "$EXECUTION_ROLE" ] || [ -z "$S3_FILES_FS_ID" ]; then
  err "Stack '$STACK_NAME' not found, or missing expected outputs."
  exit 1
fi

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

EGRESS_FLAG=""
if [ -n "$NETWORK_CONNECTOR_ARN" ] && [ "$NETWORK_CONNECTOR_ARN" != "None" ]; then
  EGRESS_FLAG="--egress-network-connectors [\"$NETWORK_CONNECTOR_ARN\"]"
fi

# To exercise the real per-user mount path (not just an unmounted VM), create
# a temporary access point and pass its id via --run-hook-payload, exactly
# as the token Lambda does for a real user.
log "Creating throwaway access point for smoke test..."
SMOKE_AP=$(aws s3files create-access-point \
  --file-system-id "$S3_FILES_FS_ID" \
  --posix-user 'uid=1000,gid=1000' \
  --root-directory 'path=/users/_smoketest,creationPermissions={ownerUid=1000,ownerGid=1000,permissions=0755}' \
  --query 'accessPointId' --output text 2>/dev/null || echo "")

log "Launching smoke-test MicroVM..."
RUN_OUT=$(aws lambda-microvms run-microvm \
  --image-identifier "$IMAGE_ARN" \
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

cleanup() {
  if [ -n "${MVM_ID:-}" ]; then
    log "Tearing down smoke-test VM..."
    aws lambda-microvms terminate-microvm --microvm-identifier "$MVM_ID" 2>/dev/null || true
  fi
  if [ -n "${SMOKE_AP:-}" ] && [ "$SMOKE_AP" != "None" ]; then
    aws s3files delete-access-point --access-point-id "$SMOKE_AP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -z "$MVM_ID" ]; then
  err "Failed to extract microvmId from run response"
  echo "$RUN_OUT" | tail -20 >&2
  exit 1
fi

ok "Smoke-test MicroVM launched: $MVM_ID"
ok "Endpoint: $MVM_ENDPOINT"
# Give snapshot boot + /run-hook mount a moment before probing.
sleep 15

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
else
  err "Could not mint a smoke-test auth token — skipping the HTTP probe."
fi

# cleanup() runs automatically via the EXIT trap above.
