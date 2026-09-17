// Merge the image-owned Claude Code permission default into the user's settings.
// This preserves all unrelated user preferences while keeping the dedicated
// MicroVM's unattended execution policy durable across image replacements.
const fs = require('fs');
const path = require('path');

const [configPath] = process.argv.slice(2);
if (!configPath) process.exit(64);

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch { /* a missing or malformed file is safely replaced with this minimum */ }
if (!config || typeof config !== 'object' || Array.isArray(config)) config = {};
if (!config.permissions || typeof config.permissions !== 'object' || Array.isArray(config.permissions)) {
  config.permissions = {};
}
config.permissions.defaultMode = 'bypassPermissions';

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('claude-settings-config: bypassPermissions enabled');
