// Merge the image-owned AgentCore web-search MCP server into the user's
// ~/.claude.json, preserving any other servers / settings they've added.
//
// Called by mount-home.sh on EVERY mount (not just first seed) so a redeploy's
// new gateway URL reaches existing per-user homes — same "image-owned, refresh
// every mount" contract as the CLAUDE.md briefing.
//
// Usage: node mcp-config.js <claude-json-path> <gateway-url>
// No gateway URL (e.g. --skip-infra before the gateway exists) → no-op.
const fs = require('fs');

const [, , configPath, gatewayUrl] = process.argv;
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
cfg.mcpServers['web-search'] = {
  command: 'uvx',
  args: [
    'mcp-proxy-for-aws@1.6.3',
    gatewayUrl,
    '--service', 'bedrock-agentcore',
    '--region', 'us-east-1',
  ],
};

fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
console.log('mcp-config: web-search MCP server registered');
