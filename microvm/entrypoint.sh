#!/bin/bash
set -e

# Cold-start note: first-touch reads on a fresh VM demand-page from snapshot
# storage (slow), which once made the first S3 Files mount take ~26s and the
# first `claude` launch 60-90s. The fix is the /validate image hook (see
# hooks.js): it exercises the real startup path — mount toolchain and Claude
# CLI included — so the platform samples those pages and prefetches them on
# every future launch. Measured: mount ready in ~4s, `claude` sub-second.
#
# If prefetch ever regresses (it's a platform optimization, not a contract),
# the previous fix was relocating the toolchain into tmpfs so it rides the
# eagerly-restored memory snapshot (~1s cold boots, at the cost of ~530MB of
# RAM on every run/resume). See git history for this file (pre-July-2026) or
# the blog post "Baking a Fast MicroVM" for the full technique.

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
