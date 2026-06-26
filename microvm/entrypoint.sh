#!/bin/bash
set -e

# Pull key binaries into page cache for faster first access after snapshot resume
cat /usr/bin/node > /dev/null 2>&1 || true
cat $(which claude 2>/dev/null) > /dev/null 2>&1 || true

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
