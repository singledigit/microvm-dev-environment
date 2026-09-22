#!/bin/sh
# Refresh image-owned Codex MCP records while keeping uv's cache off S3 Files.
# Codex preserves every unrelated setting/server in ~/.codex/config.toml.
set -eu

home_dir=${1:?usage: codex-mcp-config.sh <home-dir> <gateway-url> [configure-aws-mcp]}
gateway_url=${2:-}
configure_aws=${3:-false}
[ -n "$gateway_url" ] || exit 0

codex_bin=/opt/codex/node_modules/.bin/codex

add_server() {
  server_name=$1
  shift

  # These entries are image-owned. Removing only their names makes updated
  # endpoints and the local, hardlink-capable uv cache take effect immediately.
  sudo -u coder HOME="$home_dir" "$codex_bin" mcp remove "$server_name" >/dev/null 2>&1 || true
  sudo -u coder HOME="$home_dir" "$codex_bin" mcp add \
    --env UV_CACHE_DIR=/opt/uv/cache \
    --env UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    --env UV_TOOL_DIR=/opt/uv/tool \
    --env UV_TOOL_BIN_DIR=/opt/uv/toolbin \
    "$server_name" -- "$@" >/dev/null
}

# Signing region must match where the AgentCore Gateway was actually
# created — WEBSEARCH_REGION, not DEPLOY_REGION (where the rest of the
# stack lives) or the fixed us-east-1 AWS_REGION this image pins for
# Bedrock/Claude Code model access. See the Dockerfile's comment on
# WEBSEARCH_REGION for why these are three separate concerns.
add_server workspace-web-search \
  uvx mcp-proxy-for-aws@1.6.3 "$gateway_url" \
  --service bedrock-agentcore --region "${WEBSEARCH_REGION:-us-east-1}"

# The AWS CLI Agent Toolkit creates aws-mcp after the initial mount setup. Its
# refresh invokes this script with the third argument so this re-adds only that
# server with an explicit local uv cache as well.
if [ "$configure_aws" = "true" ]; then
  add_server aws-mcp \
    uvx mcp-proxy-for-aws@latest https://aws-mcp.us-east-1.api.aws/mcp \
    --metadata INSTALL_SOURCE=aws-cli
fi

echo 'codex-mcp-config: MCP servers registered with local uv cache'
