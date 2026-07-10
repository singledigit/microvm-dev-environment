FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# curl-minimal is pre-installed — don't reinstall curl
RUN dnf install -y \
    git \
    tar \
    gzip \
    unzip \
    which \
    shadow-utils \
    procps-ng \
    sudo \
    zsh \
    amazon-efs-utils \
    python3-pip \
    && dnf clean all

# Disable efs-utils/efs-proxy CloudWatch telemetry (mount attempts + proxy
# metrics). It cannot work here anyway — mount.s3files runs under python3.13
# (no botocore; installing it would put a ~90MB cold import on the mount's
# critical path), and efs-proxy derives a log-stream name that fails
# CloudWatch's own [^:*]* validation — so every mount logged two spurious
# errors. Mount diagnostics remain in /var/log/amazon/efs/ inside the VM.
RUN sed -i '/^\[cloudwatch-log\]/,/^\[/ s/^enabled = true/enabled = false/' \
      /etc/amazon/efs/s3files-utils.conf /etc/amazon/efs/efs-utils.conf \
    && sed -i 's/^metrics_enabled = true/metrics_enabled = false/' \
      /etc/amazon/efs/s3files-utils.conf

# Node.js (latest LTS via NodeSource)
RUN curl -fsSL https://rpm.nodesource.com/setup_24.x | bash - \
    && dnf install -y nodejs \
    && dnf clean all

# Build tools needed for native node modules (node-pty)
RUN dnf install -y python3 make gcc gcc-c++ && dnf clean all

# AWS CLI v2 — baked into the image so it survives restarts (system FS is not persisted)
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Python 3.13 as the system interpreter. AL2023 ships 3.9, but the AWS agent
# toolkit's secret-safety hook (and other tooling) needs >=3.10. uv picks its
# own compatible Python for the MCP proxy at runtime; this is just a modern
# system python3.
RUN dnf install -y python3.13 python3.13-pip \
    && dnf clean all \
    && alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 90

# uv/uvx on the SYSTEM filesystem (/opt), with all uv state pointed at /opt too.
# WHY: the AWS agent toolkit plugin launches its MCP proxy via `uvx` (stock
# config). uv relies on hardlinks for cache locking and package materialization,
# and /home/coder is an NFS mount that rejects hardlinks (EMLINK) — so uvx fails
# there no matter the link mode. /opt is a normal FS (hardlinks OK) and is baked
# into the image snapshot, so relocating uv's cache/tool/python dirs to /opt lets
# the plugin run EXACTLY as shipped — no patched .mcp.json, no re-patch hook.
# The proxy package is pre-warmed into the cache so the first `uvx` is instant
# and works offline.
ENV UV_INSTALL_DIR=/opt/uv/bin \
    UV_CACHE_DIR=/opt/uv/cache \
    UV_TOOL_DIR=/opt/uv/tool \
    UV_TOOL_BIN_DIR=/opt/uv/toolbin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN mkdir -p /opt/uv/bin /opt/uv/cache /opt/uv/tool /opt/uv/toolbin /opt/uv/python \
    && curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/opt/uv/bin sh \
    && ln -sf /opt/uv/bin/uv /usr/local/bin/uv \
    && ln -sf /opt/uv/bin/uvx /usr/local/bin/uvx \
    && /opt/uv/bin/uvx mcp-proxy-for-aws@1.6.3 --help >/dev/null 2>&1 \
    && chown -R 1000:1000 /opt/uv

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# App infrastructure lives at /opt/app — never shadowed by the S3 mount
WORKDIR /opt/app
RUN npm init -y && npm install node-pty ws && npm cache clean --force

COPY hooks.js /opt/app/hooks.js
COPY terminal.js /opt/app/terminal.js
COPY mount-home.sh /opt/app/mount-home.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /opt/app/mount-home.sh

# App user — NO -m flag: /home/coder must be empty so S3 Files can mount over it.
# zsh is the login shell.
RUN useradd -M -s /bin/zsh -u 1000 coder \
    && mkdir -p /home/coder \
    && chown 1000:1000 /home/coder

# Passwordless sudo for coder (browser terminal runs as coder).
# Note: system changes via sudo do NOT persist — only /home/coder is on S3.
RUN echo 'coder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/coder \
    && chmod 0440 /etc/sudoers.d/coder

# SHELL_INGRESS execs /bin/bash, /bin/zsh, or /bin/sh directly. Guarantee all
# exist (some base layouts only ship the /usr/bin variants).
RUN [ -e /bin/bash ] || ln -s /usr/bin/bash /bin/bash; \
    [ -e /bin/zsh ]  || ln -s /usr/bin/zsh  /bin/zsh; \
    [ -e /bin/sh ]   || ln -s /usr/bin/sh   /bin/sh; \
    true

# Seed defaults — copied into /home/coder on first S3 mount (empty filesystem)
RUN mkdir -p /etc/skel-coder/.claude/skills
COPY zshrc /etc/skel-coder/.zshrc
COPY bashrc /etc/skel-coder/.bashrc
COPY skills/ /etc/skel-coder/.claude/skills/

RUN cat > /etc/skel-coder/.claude.json <<'EOF'
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "99.0.0",
  "lastReleaseNotesSeen": "99.0.0",
  "theme": "dark",
  "autoUpdates": false,
  "bypassPermissionsModeAccepted": true,
  "projects": {
    "/home/coder": {
      "hasTrustDialogAccepted": true,
      "projectOnboardingSeenCount": 1
    }
  }
}
EOF

RUN echo '{"permissions":{"defaultMode":"bypassPermissions"}}' \
    > /etc/skel-coder/.claude/settings.json

# Environment briefing for the in-VM Claude: where it runs, what persists, and
# the local gotchas (NFS hardlinks, WebFetch, IAM scope, lifecycle). Refreshed
# into /home/coder on every mount by mount-home.sh, not just first seed, so
# updates reach existing users.
RUN cat > /etc/skel-coder/.claude/CLAUDE.md <<'EOF'
# Your environment: a personal cloud sandbox VM

You are running inside a dedicated AWS Lambda MicroVM (Firecracker-isolated,
Amazon Linux 2023, aarch64, 8 GB RAM) that belongs entirely to this user and
is reached through a browser terminal. Act accordingly: you have far more
freedom here than in a typical local checkout, and different persistence rules.

## What you can do freely
- Full shell as `coder` with passwordless sudo. Installing packages (dnf, npm,
  pip), running servers, compiling, long builds — all fine, no approval needed.
- Outbound network from Bash is fully open (curl, git clone, package registries).
- This VM is isolated per user: nothing you run here can affect other users.

## What persists (and what does not)
- ONLY `/home/coder` persists. It is an NFS mount backed by Amazon S3, scoped
  to this user, and it survives VM restarts and recycles.
- Everything else — `sudo dnf install`, `npm install -g`, system config — is on
  the VM image and resets when the VM is recycled. If the user needs a tool
  long-term, install it into the home directory or add the install command to
  `~/.zshrc` so it self-heals on a fresh VM.
- The home filesystem rejects hardlinks (EMLINK). Tools that depend on them
  should keep caches/state outside home: uv is already configured for /opt/uv;
  point similar tools at /tmp or /opt if they fail oddly in $HOME.

## Credentials and AWS access
- There are no API keys anywhere. AWS access comes from the VM's IAM execution
  role via IMDSv2. You (Claude Code) run through Amazon Bedrock using that role.
- The role is intentionally narrow: Bedrock model invocation + the S3 Files
  home mount. `aws sts get-caller-identity` works, but do not expect broad AWS
  permissions — if the user wants to manage AWS resources, they should provide
  scoped credentials themselves.

## VM lifecycle — checkpoint long work
- Idle is measured by INBOUND browser traffic only. If the user closes the tab,
  the VM suspends after ~2 hours (your process freezes mid-instruction and
  resumes later; in-flight network calls will have died — just retry). A VM
  lives at most 8 hours, then terminates.
- Therefore: for long-running jobs, write progress and results to files under
  /home/coder as you go. Files survive termination; your session does not.

## Tool quirks
- WebFetch and WebSearch do not work here: their domain-safety verification
  endpoint (claude.ai) is blocked from this network, so every fetch is rejected
  as "unverifiable" even though the target site is reachable.
- Use curl via Bash instead, e.g.: curl -s "https://example.com"  or
  curl -s "wttr.in/London?format=3"
EOF

# Bedrock — uses execution role via IMDSv2
ENV HOME=/home/coder
ENV S3_FILES_FS_ID=__S3_FILES_FS_ID__
ENV CLAUDE_CODE_USE_BEDROCK=1
ENV AWS_REGION=us-east-1
# Default model: Opus (Fable requires US data residency; users may be outside US).
# Fable available via: /model us.anthropic.claude-fable-5
ENV ANTHROPIC_MODEL=us.anthropic.claude-opus-4-8
ENV ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
ENV ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-5
ENV ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
ENV ANTHROPIC_SMALL_FAST_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV DISABLE_AUTOUPDATER=1
ENV DO_NOT_TRACK=1

EXPOSE 8080 9000

ENTRYPOINT ["/entrypoint.sh"]
