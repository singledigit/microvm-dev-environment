#!/bin/bash
# Build a DEV MicroVM image (ipad-claude-dev) from the working tree's microvm/.
# Production image (IMAGE_NAME from config.env) and per-user VMs are untouched.
# Usage: ./scripts/deploy-dev-image.sh
set -euo pipefail

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(unset CDPATH; cd "$SCRIPT_DIR/.." && pwd)"
set -a; . "$ROOT_DIR/config.env"; set +a

PROFILE="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-ipad-claude}"
DEV_IMAGE_NAME="ipad-claude-dev"
ZIP_KEY="ipad-claude-microvm-dev.zip"

out() { aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --profile "$PROFILE" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
ARTIFACT_BUCKET=$(out ArtifactBucketName)
BUILD_ROLE=$(out BuildRoleArn)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)

echo "Packaging microvm/ → s3://$ARTIFACT_BUCKET/$ZIP_KEY"
BUILD_DIR="/tmp/ipad-claude-microvm-dev-build"
rm -rf "$BUILD_DIR"; cp -R "$ROOT_DIR/microvm" "$BUILD_DIR"
sed -i.bak "s|^ENV S3_FILES_FS_ID=.*|ENV S3_FILES_FS_ID=${S3_FILES_FS_ID}|" "$BUILD_DIR/Dockerfile"
rm -f "$BUILD_DIR/Dockerfile.bak"
rm -f "/tmp/$ZIP_KEY"
(cd "$BUILD_DIR" && zip -r "/tmp/$ZIP_KEY" . -x "*.DS_Store" > /dev/null)
aws s3 cp "/tmp/$ZIP_KEY" "s3://$ARTIFACT_BUCKET/$ZIP_KEY" --profile "$PROFILE"

HOOKS_JSON='{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":180,"validate":"ENABLED","validateTimeoutInSeconds":300},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":10,"resume":"ENABLED","resumeTimeoutInSeconds":10,"suspend":"ENABLED","suspendTimeoutInSeconds":10,"terminate":"ENABLED","terminateTimeoutInSeconds":10}}'

IMAGE_ID=$(aws lambda-microvms list-microvm-images \
  --profile "$PROFILE" --region "$REGION" \
  --query "items[?name=='$DEV_IMAGE_NAME'].imageArn | [0]" --output text 2>/dev/null || echo "")

if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" = "None" ]; then
  echo "Creating dev image $DEV_IMAGE_NAME..."
  IMAGE_ID=$(aws lambda-microvms create-microvm-image \
    --name "$DEV_IMAGE_NAME" \
    --base-image-arn "arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
    --additional-os-capabilities '["ALL"]' \
    --hooks "$HOOKS_JSON" \
    --environment-variables "{\"S3_FILES_FS_ID\":\"$S3_FILES_FS_ID\"}" \
    --profile "$PROFILE" --region "$REGION" \
    --query imageArn --output text)
else
  echo "Updating dev image $IMAGE_ID..."
  aws lambda-microvms update-microvm-image \
    --image-identifier "$IMAGE_ID" \
    --base-image-arn "arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/$ZIP_KEY\"}" \
    --additional-os-capabilities '["ALL"]' \
    --hooks "$HOOKS_JSON" \
    --environment-variables "{\"S3_FILES_FS_ID\":\"$S3_FILES_FS_ID\"}" \
    --profile "$PROFILE" --region "$REGION" --output json > /dev/null
fi

echo "Image: $IMAGE_ID — waiting for build..."
for i in $(seq 1 120); do
  J=$(aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ID" \
    --profile "$PROFILE" --region "$REGION" --output json 2>/dev/null || echo '{}')
  STATE=$(echo "$J" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))")
  VER=$(echo "$J" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latestActiveImageVersion',''))")
  if { [ "$STATE" = "UPDATED" ] || [ "$STATE" = "CREATED" ]; } && [ -n "$VER" ]; then
    echo "Dev image ready: $IMAGE_ID (version $VER)"; exit 0
  elif [[ "$STATE" == *"FAIL"* ]]; then
    echo "Dev image build FAILED: $STATE" >&2; echo "$J" >&2; exit 1
  fi
  printf "\r  state: %-25s (%d/120)" "$STATE" "$i"; sleep 10
done
echo "Timed out waiting for image build" >&2; exit 1
