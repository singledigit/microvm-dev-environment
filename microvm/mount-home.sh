#!/bin/bash
# Mount THIS user's S3 Files home directory.
#
# Invoked by the /run and /resume lifecycle hooks (hooks.js) with the per-user
# access-point id — NOT at boot. The image snapshot is shared across every VM,
# so the mount cannot be baked in at build time: each VM must mount its own
# user's access point at run time, and the access-point id only arrives via the
# /run hook payload (post-resume). Idempotent — safe to call on both /run and
# /resume, and safe if the mount already exists.
#
# Runs in the background (the hook returns 200 immediately); terminal.js waits
# for /tmp/home-ready before spawning the shell.
set +e

ACCESS_POINT="$1"
MOUNT_PATH="/home/coder"
FS_ID="${S3_FILES_FS_ID:-}"
HOME_READY="/tmp/home-ready"
SKEL="/etc/skel-coder"

# Already mounted (resume after a surviving mount, or a double hook)? Done.
if mountpoint -q "$MOUNT_PATH"; then
  echo "mount-home: already mounted at $MOUNT_PATH" >> /tmp/hooks.log
  touch "$HOME_READY"
  exit 0
fi

rm -f "$HOME_READY" /tmp/home-ready-failed

# Fail SAFE: never mount the filesystem root as a fallback — that would share
# one home across all users. No access point → run without persistence.
if [ -z "$FS_ID" ] || [ -z "$ACCESS_POINT" ]; then
  echo "mount-home: missing FS_ID or access point — running without persistence" >> /tmp/hooks.log
  touch /tmp/home-ready-failed "$HOME_READY"
  exit 0
fi

echo "mount-home: mounting $FS_ID (accesspoint=$ACCESS_POINT) at $MOUNT_PATH..." >> /tmp/hooks.log
MOUNTED=false
for attempt in 1 2 3 4 5 6; do
  if mount -t s3files -o "accesspoint=$ACCESS_POINT" "$FS_ID" "$MOUNT_PATH" 2>>/tmp/hooks.log; then
    echo "mount-home: mounted on attempt $attempt" >> /tmp/hooks.log
    # Seed defaults on first use (empty home). Never let a seed error abort —
    # NFS-managed entries like .s3files-lost+found reject chown, so guard each.
    if [ ! -f "$MOUNT_PATH/.zshrc" ]; then
      echo "mount-home: new home — seeding defaults" >> /tmp/hooks.log
      cp -r "$SKEL/." "$MOUNT_PATH/" 2>>/tmp/hooks.log || echo "mount-home: seed copy partial" >> /tmp/hooks.log
      for entry in "$SKEL"/* "$SKEL"/.[!.]*; do
        [ -e "$entry" ] || continue
        chown -R 1000:1000 "$MOUNT_PATH/$(basename "$entry")" 2>>/tmp/hooks.log || true
      done
      echo "mount-home: seed complete" >> /tmp/hooks.log
    fi
    MOUNTED=true
    break
  fi
  echo "mount-home: attempt $attempt failed, retrying in 5s..." >> /tmp/hooks.log
  sleep 5
done

if [ "$MOUNTED" = false ]; then
  echo "mount-home: failed after 6 attempts — running without persistence" >> /tmp/hooks.log
  touch /tmp/home-ready-failed
fi
touch "$HOME_READY"
