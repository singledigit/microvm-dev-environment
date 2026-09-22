#!/bin/bash
# Deploy the frontend to a DEV channel: same bucket/distribution, /dev.html key.
# Production (/index.html) is untouched. A build stamp (git short SHA + time)
# is injected into window.APP_CONFIG and shown in the header so a phone can
# confirm which build it's actually running.
# Usage: ./scripts/deploy-dev.sh
set -euo pipefail

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"
STACK_NAME="remote-developer"

out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

TOKEN_API_URL=$(out TokenApiUrl)
USER_POOL_ID=$(out UserPoolId)
USER_POOL_CLIENT_ID=$(out UserPoolClientId)
FRONTEND_BUCKET=$(out FrontendBucketName)
CF_DIST_ID=$(out CloudFrontDistributionId)
FRONTEND_URL=$(out FrontendUrl)

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
BUILD_STAMP="$(git -C "$ROOT_DIR" rev-parse --short HEAD)-$(date +%H%M%S)"
APP_CONFIG_JSON="{\"tokenApiUrl\":\"$TOKEN_API_URL\",\"region\":\"$REGION\",\"userPoolId\":\"$USER_POOL_ID\",\"userPoolClientId\":\"$USER_POOL_CLIENT_ID\",\"build\":\"$BUILD_STAMP\"}"

RENDERED=/tmp/remote-developer-dev.html
sed "s|<script>window.APP_CONFIG = {}; /\* APP_CONFIG_PLACEHOLDER \*/</script>|<script>window.APP_CONFIG = $APP_CONFIG_JSON;</script>|" \
  "$ROOT_DIR/frontend/index.html" > "$RENDERED"

aws s3 cp "$RENDERED" "s3://$FRONTEND_BUCKET/dev.html" \
  --cache-control "no-cache" --content-type "text/html"
if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
  aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" \
    --paths "/dev.html" > /dev/null
fi
echo "dev build $BUILD_STAMP → $FRONTEND_URL/dev.html"
