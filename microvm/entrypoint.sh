#!/bin/bash
set -e

# Move the Claude CLI bundle into tmpfs so it lands in the MEMORY snapshot,
# which is eagerly restored on run/resume. Plain page-cache warming does NOT
# survive snapshot capture (the platform drops clean file-backed pages), so on
# a fresh VM the first `claude` demand-pages ~240MB of disk from snapshot
# storage at ~3MB/s — a 60-90s stall. tmpfs pages are anonymous memory and
# must be preserved, so this makes first start as fast as every later start.
# This runs once at image build; the snapshot captures the tmpfs contents.
CLI_DIR=/usr/lib/node_modules/@anthropic-ai/claude-code
if [ -d "$CLI_DIR" ] && ! mountpoint -q "$CLI_DIR" 2>/dev/null; then
  if mv "$CLI_DIR" "${CLI_DIR}.disk" \
     && mkdir "$CLI_DIR" \
     && mount -t tmpfs -o size=512m,mode=0755 tmpfs "$CLI_DIR" \
     && cp -a "${CLI_DIR}.disk/." "$CLI_DIR/"; then
    echo "claude bundle relocated to tmpfs" >> /tmp/hooks.log
  else
    # Roll back so the CLI still works from disk
    umount "$CLI_DIR" 2>/dev/null || true
    rmdir "$CLI_DIR" 2>/dev/null || true
    [ -d "${CLI_DIR}.disk" ] && mv "${CLI_DIR}.disk" "$CLI_DIR"
    echo "tmpfs relocation failed — claude stays on disk" >> /tmp/hooks.log
  fi
fi

# Start the lifecycle hooks server. It performs the per-user S3 Files mount on
# the /run and /resume hooks (NOT here): the image snapshot is shared across
# all VMs, so the mount can't be baked in at build time — each VM mounts its
# own user's access point at run time, with the id delivered in the /run
# payload. See hooks.js + mount-home.sh. terminal.js waits for /tmp/home-ready
# (which the mount signals) before spawning the shell.
node /opt/app/hooks.js > /tmp/hooks.log 2>&1 &

# Start terminal server — shell spawns lazily on first client resize, and only
# after /tmp/home-ready appears (set by the mount running in the /run hook).
exec node /opt/app/terminal.js
