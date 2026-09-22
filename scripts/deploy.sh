#!/bin/bash
# Deploy the SAM stack (infrastructure) and sync the frontend. Usage:
#   ./scripts/deploy.sh [--skip-infra]
#     --skip-infra   skip sam build/deploy — frontend sync only
#
# This is a convenience wrapper around the README's "Step 1 — Deploy the
# infrastructure with SAM" (plus the frontend sync from Configure). The
# README shows every command this runs directly, in order, with an
# explanation of what each one does and why — read that first if you
# haven't. This script deliberately does NOT build the MicroVM image or
# launch a smoke-test VM — those are README Steps 2-5, with their own
# convenience wrappers (build-microvm-image.sh, smoke-test-vm.sh) run
# separately, after this one finishes.
#
# No project-specific config file for profile/region/account: sam build and
# sam deploy read stack_name/region/profile from samconfig.toml on their own
# (that's what it's for — see samconfig.toml.example). This script's own raw
# `aws` calls (the frontend upload, the CloudFront invalidation — not `sam`
# commands, so samconfig.toml doesn't apply to them) rely on the SAME
# standard AWS CLI resolution every script does: AWS_PROFILE / AWS_REGION
# env vars, or your default profile. Export them once, or run
# `AWS_PROFILE=... AWS_REGION=... ./scripts/deploy.sh` — nothing here parses
# a config file to re-derive them.
set -euo pipefail

# Resolve repo root from this script's location (no hardcoded path).
# Unset CDPATH first: if it's set in the user's env, `cd` echoes the target
# dir to stdout, which would corrupt the command substitution below.
SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"

# Fixed identifier for this app's stack — matches samconfig.toml's own
# stack_name literal (the two are independent tools/files, kept in sync by
# hand; this rarely changes). Not a config knob.
STACK_NAME="remote-developer"

SKIP_INFRA=false
for arg in "$@"; do
  case $arg in
    --skip-infra) SKIP_INFRA=true ;;
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

# ── Infrastructure: SAM build + deploy ──────────────────────────────────────
# No --profile/--region/--stack-name here — sam reads all three from
# samconfig.toml on its own. No --parameter-overrides needed either: the
# template's only Parameter (LoginEmail) has a default, and the MicroVM
# image is no longer a stack resource at all — see build-microvm-image.sh.
# That means a bare `sam deploy` succeeds on a brand-new account with
# nothing to bootstrap.
if [ "$SKIP_INFRA" = false ]; then
  log "Building SAM application..."
  (cd "$ROOT_DIR" && sam build --template template.yaml)

  log "Deploying SAM stack..."
  (cd "$ROOT_DIR" && sam deploy --no-confirm-changeset --no-fail-on-empty-changeset)
  ok "SAM stack deployed"
else
  log "Skipping infra (--skip-infra), using existing stack outputs..."
fi

# ── Read stack outputs (SAM creates a normal CloudFormation stack) ────────────
# TokenApiUrl/FrontendUrl/UserPoolId/LoginEmail/CreateUserCommand etc. were
# already printed by `sam deploy` itself moments ago (when --skip-infra is
# false) — only re-read here what this script actually needs: the frontend
# sync.
FRONTEND_BUCKET=$(out FrontendBucketName)
CF_DIST_ID=$(out CloudFrontDistributionId)
USER_POOL_ID=$(out UserPoolId)
USER_POOL_CLIENT_ID=$(out UserPoolClientId)
TOKEN_API_URL=$(out TokenApiUrl)

if [ -z "$FRONTEND_BUCKET" ]; then
  err "Stack '$STACK_NAME' not found (or missing outputs) — run without" \
      "--skip-infra at least once first."
  exit 1
fi

# ── Inject runtime config into frontend (token API + Cognito ids) ─────────────
# index.html ships with an APP_CONFIG placeholder; fill it at deploy time. We
# render to a temp copy so the committed file keeps its placeholder (no
# account-specific values ever land in git).
log "Injecting runtime config into frontend..."
FRONTEND_FILE="$ROOT_DIR/frontend/index.html"
RENDERED=/tmp/remote-developer-index.html
APP_CONFIG_JSON="{\"tokenApiUrl\":\"$TOKEN_API_URL\",\"region\":\"$(aws configure get region 2>/dev/null || echo us-east-1)\",\"userPoolId\":\"$USER_POOL_ID\",\"userPoolClientId\":\"$USER_POOL_CLIENT_ID\"}"
# Replace the whole placeholder <script> line with the injected config.
sed "s|<script>window.APP_CONFIG = {}; /\* APP_CONFIG_PLACEHOLDER \*/</script>|<script>window.APP_CONFIG = $APP_CONFIG_JSON;</script>|" \
  "$FRONTEND_FILE" > "$RENDERED"

log "Syncing frontend to S3 ($FRONTEND_BUCKET)..."
aws s3 cp "$RENDERED" "s3://$FRONTEND_BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html"
rm -f "$RENDERED"

if [ -n "$CF_DIST_ID" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$CF_DIST_ID" \
    --paths "/*" > /dev/null
fi
ok "Frontend synced and CDN invalidated"

# ── Done ──────────────────────────────────────────────────────────────────────
# TokenApiUrl/FrontendUrl/UserPoolId/LoginEmail/CreateUserCommand were all
# already printed by `sam deploy` itself above. Next steps, in order:
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Remote Developer — Infrastructure deployed"
echo ""
echo "  Next: build the MicroVM image (README Steps 2-4):"
echo "    ./scripts/build-microvm-image.sh"
echo ""
echo "  Then, optionally, verify the image boots (README Step 5):"
echo "    ./scripts/smoke-test-vm.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
