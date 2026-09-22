// Merge the image-owned AgentCore web-search MCP server into a JSON-based
// user configuration, preserving every unrelated server and top-level setting.
//
// Used for Claude's ~/.claude.json and Kiro's ~/.kiro/settings/mcp.json. Each
// caller owns one named record and refreshes it on every mounted workspace.
//
// Usage: node mcp-config.js <json-config-path> <gateway-url> [server-name]
// No gateway URL (e.g. --skip-infra before the gateway exists) → no-op.
const fs = require('fs');
const path = require('path');

const [, , configPath, gatewayUrl, serverName = 'web-search'] = process.argv;
if (!gatewayUrl || !configPath) process.exit(0);

// SigV4 signing region for the gateway call — this MUST match the region the
// AgentCore Gateway was actually created in. That's WEBSEARCH_REGION, NOT
// DEPLOY_REGION (where the rest of the stack lives) or AWS_REGION (pinned to
// us-east-1 for Bedrock/Claude Code model access) — the web-search connector
// is only enabled per-account in specific regions today, so
// build-microvm-image.sh creates the gateway in its own region
// (WEBSEARCH_REGION, us-east-1 by default) independent of where the stack
// itself deploys. See the Dockerfile's comment on WEBSEARCH_REGION.
const signingRegion = process.env.WEBSEARCH_REGION || 'us-east-1';

let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch { /* missing or corrupt — start fresh, seeding restores the rest */ }
if (!cfg || typeof cfg !== 'object') cfg = {};
if (!cfg.mcpServers || typeof cfg.mcpServers !== 'object') cfg.mcpServers = {};

// SigV4-signed MCP over the baked, pre-warmed proxy. The gateway URL is baked
// into the args here (not read from env at runtime) so the server config is
// self-contained. Signing service is `bedrock-agentcore`, matching AWS's own
// AgentCore web-search example; if signing is ever rejected, the documented
// alternative for a gateway is `agent-registry`.
cfg.mcpServers[serverName] = {
  command: 'uvx',
  args: [
    'mcp-proxy-for-aws@1.6.3',
    gatewayUrl,
    '--service', 'bedrock-agentcore',
    '--region', signingRegion,
  ],
};

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
console.log(`mcp-config: ${serverName} MCP server registered`);
