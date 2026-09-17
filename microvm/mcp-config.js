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
    '--region', 'us-east-1',
  ],
};

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
console.log(`mcp-config: ${serverName} MCP server registered`);
