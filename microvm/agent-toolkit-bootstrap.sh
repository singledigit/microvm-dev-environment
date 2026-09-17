#!/bin/sh
# Refresh the official Agent Toolkit for AWS in the mounted, per-user home.
# This intentionally runs after the S3 Files mount: skills, plugin metadata,
# MCP records, and any CLI caches belong to the user, never to the shared image.
set -u

home_dir=${1:?usage: agent-toolkit-bootstrap.sh <home-dir>}
status_file="$home_dir/.agent-toolkit-status"

run_as_coder() {
  sudo -u coder env \
    HOME="$home_dir" \
    AWS_REGION="${AWS_REGION:-us-east-1}" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    UV_CACHE_DIR=/opt/uv/cache \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tool \
    UV_TOOL_BIN_DIR=/opt/uv/toolbin \
    "$@"
}

printf 'Updating Agent Toolkit for AWS...\n' > "$status_file"
chown coder:coder "$status_file" 2>/dev/null || true

# AWS CLI installs the latest default AWS skills for Claude, Codex, and Kiro,
# and merges its aws-mcp record into each detected agent's user configuration.
if ! timeout 300 sudo -u coder env \
  HOME="$home_dir" \
  AWS_REGION="${AWS_REGION:-us-east-1}" \
  PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  UV_CACHE_DIR=/opt/uv/cache \
  UV_PYTHON_INSTALL_DIR=/opt/uv/python \
  UV_TOOL_DIR=/opt/uv/tool \
  UV_TOOL_BIN_DIR=/opt/uv/toolbin \
  aws configure agent-toolkit --yes; then
  printf 'Agent Toolkit refresh did not complete. Check /tmp/hooks.log.\n' > "$status_file"
  chown coder:coder "$status_file" 2>/dev/null || true
  exit 0
fi

# Keep the official AWS core plugins current for Claude Code and Codex. Each
# command is scoped to the user home and preserves user projects and login state.
run_as_coder claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 || true
run_as_coder claude plugin marketplace update claude-plugins-official >/dev/null 2>&1 || true
run_as_coder claude plugin install aws-core@claude-plugins-official --scope user -y >/dev/null 2>&1 || true
run_as_coder claude plugin update aws-core@claude-plugins-official >/dev/null 2>&1 || true

run_as_coder /opt/codex/node_modules/.bin/codex plugin marketplace add aws/agent-toolkit-for-aws >/dev/null 2>&1 || true
run_as_coder /opt/codex/node_modules/.bin/codex plugin marketplace upgrade agent-toolkit-for-aws >/dev/null 2>&1 || true
run_as_coder /opt/codex/node_modules/.bin/codex plugin add aws-core@agent-toolkit-for-aws >/dev/null 2>&1 || true

# The AWS CLI writes aws-mcp without the uv cache environment. Reconcile the
# image-owned Codex MCP records after that refresh so both proxies start from
# the hardlink-capable /opt cache instead of S3 Files.
if [ -n "${WEBSEARCH_GATEWAY_URL:-}" ]; then
  /opt/app/codex-mcp-config.sh "$home_dir" "$WEBSEARCH_GATEWAY_URL" true >/dev/null 2>&1 || true
fi

printf 'Agent Toolkit for AWS refreshed.\n' > "$status_file"
chown coder:coder "$status_file" 2>/dev/null || true
echo 'agent-toolkit: refresh complete'
