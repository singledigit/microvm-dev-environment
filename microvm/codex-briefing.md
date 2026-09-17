> **Image-managed MicroVM guidance.** This file is refreshed on every workspace mount. To replace these global Codex instructions, create `~/.codex/AGENTS.override.md`. Put project-specific guidance in an `AGENTS.md` inside that project.

# Remote development workspace

You are running in a dedicated AWS Lambda MicroVM, reached through a browser terminal.

- Only `/home/coder` persists. It is an S3 Files-backed mount scoped to this user. The system filesystem resets when the MicroVM is replaced.
- The home filesystem rejects hardlinks. Keep tools that require hardlink-capable caches on `/opt` or `/tmp`; `uv` is already configured to use `/opt/uv`.
- AWS access uses the MicroVM execution role through IMDS. No static credentials or API keys are stored in the workspace.
- `$MICROVM_ID` identifies this workspace. It can suspend after idle time and terminates after its maximum lifetime, so save long-running work under `/home/coder`.
- The `workspace-web-search` MCP server provides managed AgentCore web search. Use it for current information when available.
