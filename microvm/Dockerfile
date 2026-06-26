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
    amazon-efs-utils \
    python3-pip \
    && dnf clean all \
    && pip3 install botocore

# Node.js 20
RUN curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - \
    && dnf install -y nodejs \
    && dnf clean all

# Build tools needed for native node modules (node-pty)
RUN dnf install -y python3 make gcc gcc-c++ && dnf clean all

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# App infrastructure lives at /opt/app — never shadowed by the S3 mount
WORKDIR /opt/app
RUN npm init -y && npm install node-pty ws && npm cache clean --force

COPY hooks.js /opt/app/hooks.js
COPY terminal.js /opt/app/terminal.js
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# App user — NO -m flag: /home/coder must be empty so S3 Files can mount over it
RUN useradd -M -s /bin/bash -u 1000 coder \
    && mkdir -p /home/coder \
    && chown 1000:1000 /home/coder

# SHELL_INGRESS execs /bin/bash or /bin/sh directly. Guarantee both exist
# (some base layouts only ship /usr/bin/bash).
RUN [ -e /bin/bash ] || ln -s /usr/bin/bash /bin/bash; \
    [ -e /bin/sh ]   || ln -s /usr/bin/sh   /bin/sh; \
    true

# Seed defaults — copied into /home/coder on first S3 mount (empty filesystem)
RUN mkdir -p /etc/skel-coder/.claude/skills
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

# Bedrock — uses execution role via IMDSv2
ENV HOME=/home/coder
ENV S3_FILES_FS_ID=fs-08fd8645a4c0f5b1f
ENV CLAUDE_CODE_USE_BEDROCK=1
ENV AWS_REGION=us-east-1
ENV ANTHROPIC_MODEL=us.anthropic.claude-opus-4-8
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV DISABLE_AUTOUPDATER=1
ENV DO_NOT_TRACK=1

EXPOSE 8080 9000

ENTRYPOINT ["/entrypoint.sh"]
