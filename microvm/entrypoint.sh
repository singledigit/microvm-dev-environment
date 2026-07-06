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

# Log hooks server output so failures are visible
node /opt/app/hooks.js > /tmp/hooks.log 2>&1 &

# Mount home directly — don't rely on the /run hook being delivered.
# hooks.js still handles unmount on suspend/terminate.
MOUNT_PATH="/home/coder"
FS_ID="${S3_FILES_FS_ID:-}"
HOME_READY="/tmp/home-ready"
SKEL="/etc/skel-coder"

if [ -z "$FS_ID" ]; then
  echo "S3_FILES_FS_ID not set — skipping mount" | tee -a /tmp/hooks.log
  touch "$HOME_READY"
else
  echo "Mounting s3files $FS_ID at $MOUNT_PATH..." | tee -a /tmp/hooks.log
  MOUNTED=false
  for attempt in 1 2 3 4 5 6; do
    if mount -t s3files "${FS_ID}:/" "$MOUNT_PATH" 2>>/tmp/hooks.log; then
      echo "Mount succeeded on attempt $attempt" | tee -a /tmp/hooks.log
      # Seed defaults on first use (empty filesystem). Never let a seed error
      # abort the entrypoint — the terminal must start regardless. NFS-managed
      # entries like .s3files-lost+found reject chown, so guard every step.
      if [ ! -f "$MOUNT_PATH/.bashrc" ]; then
        echo "New filesystem — seeding defaults..." | tee -a /tmp/hooks.log
        cp -r "$SKEL/." "$MOUNT_PATH/" 2>>/tmp/hooks.log || echo "seed copy partial" | tee -a /tmp/hooks.log
        # chown only the files we seeded, skipping NFS-managed lost+found dirs
        for entry in "$SKEL"/* "$SKEL"/.[!.]*; do
          [ -e "$entry" ] || continue
          base=$(basename "$entry")
          chown -R 1000:1000 "$MOUNT_PATH/$base" 2>>/tmp/hooks.log || true
        done
        echo "Seed complete" | tee -a /tmp/hooks.log
      fi
      MOUNTED=true
      break
    else
      echo "Mount attempt $attempt failed, retrying in 5s..." | tee -a /tmp/hooks.log
      sleep 5
    fi
  done
  if [ "$MOUNTED" = false ]; then
    echo "Mount failed after 6 attempts — running without persistence" | tee -a /tmp/hooks.log
    touch /tmp/home-ready-failed
  fi
  touch "$HOME_READY"
fi

# Start terminal server — shell spawns lazily on first client resize
exec node /opt/app/terminal.js
