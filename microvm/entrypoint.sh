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

# Same disease, same cure for the S3 Files mount stack: mount.s3files is a
# Python script, so the first mount on a fresh VM demand-pages python3.13
# (~67MB interpreter+stdlib) plus the 24MB efs-proxy from snapshot storage at
# ~3MB/s — measured 15-30s of the mount's wall clock. Copy the stack into
# tmpfs and bind it over the originals so it rides the memory snapshot and the
# /run-hook mount starts executing instantly. node is here because hooks.js /
# terminal.js run on it and even a RUNNING process's file-backed text pages
# are dropped at snapshot capture — the hook server itself demand-pages node
# on resume. Per-file failures are non-fatal: an unbound path just stays on
# disk (slow but correct).
WARM=/opt/warm-mount-stack
MOUNT_STACK=(
  /usr/lib64/python3.13
  /usr/lib/python3.13
  /usr/lib64/libpython3.13.so.1.0
  /usr/bin/python3.13
  /usr/lib64/libssl.so.3
  /usr/lib64/libcrypto.so.3
  /usr/sbin/efs-proxy
  /usr/sbin/efs_utils_common
  /usr/sbin/mount_s3files
  /usr/sbin/mount.s3files
  /usr/sbin/mount.nfs
  /etc/amazon/efs
  /usr/bin/node
  /usr/bin/bash
  /usr/bin/mount
  /usr/bin/mountpoint
)
if ! mountpoint -q "$WARM" 2>/dev/null; then
  mkdir -p "$WARM"
  if mount -t tmpfs -o size=320m,mode=0755 tmpfs "$WARM"; then
    for src in "${MOUNT_STACK[@]}"; do
      real=$(readlink -f "$src")            # bind the target, not the symlink
      [ -e "$real" ] || continue
      dst="$WARM/$(echo "$real" | tr / _)"  # unique name per path (two python3.13 dirs)
      if cp -a "$real" "$dst" 2>/dev/null && mount --bind "$dst" "$real" 2>/dev/null; then
        :
      else
        echo "mount-stack warm: $real stays on disk" >> /tmp/hooks.log
      fi
    done
    echo "mount stack relocated to tmpfs" >> /tmp/hooks.log
  else
    rmdir "$WARM" 2>/dev/null || true
    echo "mount-stack tmpfs failed — mount stack stays on disk" >> /tmp/hooks.log
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
