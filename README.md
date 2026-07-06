# iPad Claude Code

A browser-based terminal — built for the iPad, works anywhere — that runs
[Claude Code](https://www.anthropic.com/claude-code) inside an **AWS Lambda
MicroVM**, with a persistent home directory backed by **Amazon S3**. Open a URL,
log in, and you're in a real shell with Claude Code running against Amazon
Bedrock. Close the tab and come back later — your files, history, and installed
tools are still there.

> ⚠️ **This is a demo / personal-sandbox project, not a hardened multi-tenant
> product.** It uses a single shared password and a broadly-privileged AWS role.
> Read the [Security](#security) section before deploying anywhere others can
> reach it.

---

## How it works

```
  Browser (xterm.js)                    AWS
  ┌────────────────┐   HTTPS      ┌──────────────────────────────┐
  │  login screen  │ ───────────▶ │  API Gateway → token Lambda  │  validates password,
  │                │  password    │                              │  ensures a MicroVM is
  │                │ ◀─────────── │  returns {token, endpoint}   │  running, mints a token
  │                │   token      └──────────────────────────────┘
  │                │
  │   terminal     │   WebSocket (wss, ttyd protocol)
  │   (xterm.js)   │ ═══════════════════════════════▶  Lambda MicroVM
  └────────────────┘   auth via subprotocol            ┌────────────────────────┐
        ▲                                               │ terminal.js (PTY :8080)│
        │ served by                                     │ zsh → claude (Bedrock) │
  ┌─────────────┐                                       │ /home/coder ← S3 Files │
  │ CloudFront  │ ← S3 (frontend/index.html)            └────────────────────────┘
  └─────────────┘
```

- **Frontend** — a single `index.html` (xterm.js) on S3, served via CloudFront.
  Login validates a password, then opens a WebSocket straight to the MicroVM's
  service-managed endpoint, authenticating via the `lambda-microvms.*`
  subprotocols. On the wire it speaks the ttyd binary protocol.
- **Token Lambda** (behind API Gateway) — validates the password (stored in SSM
  Parameter Store), then resumes a suspended MicroVM or launches a fresh one,
  and mints a short-lived auth token. Uses hand-rolled SigV4 so it's immune to
  AWS CLI command-name churn.
- **MicroVM image** — Amazon Linux 2023 + Node, Python 3.13, the AWS CLI, `uv`,
  and Claude Code (pointed at Bedrock). `terminal.js` is a WebSocket PTY server
  (one shared shell, multiple attach/detach clients). `/home/coder` is an S3
  Files (NFS) mount, so the home directory persists across restarts and image
  rebuilds.
- **CDK stack** — VPC + security group, the S3 buckets (frontend / artifacts /
  workspace), IAM roles, the token Lambda + API Gateway, CloudFront, and a
  Lambda Network Connector for VPC egress to the S3 Files mount targets.

Default model is **Claude Opus 4.8** on Bedrock; `/model` switches to Fable 5,
Sonnet 5, or Haiku 4.5 (Fable requires US data residency, hence Opus as the
portable default).

---

## Prerequisites

- An AWS account with **Bedrock model access enabled** for the Claude models you
  want (Opus 4.8 at minimum).
- **AWS Lambda MicroVMs** available in your region (this project uses
  `us-east-1`). MicroVMs are a newer capability — make sure your account/region
  has access.
- Local tooling: **AWS CLI v2**, **Node.js 20+**, **Docker not required** (the
  image is built server-side by the MicroVM build service).
- **An S3 Files filesystem, created ahead of time.** ⚠️ The CDK stack does *not*
  create this — it only provisions the access role and VPC mount targets, and
  references the filesystem by ID. Create an S3 Files filesystem in the same
  region, note its `fs-...` ID, and put it in `config.env` (below). The
  filesystem's resource policy must allow the `IpadClaudeS3FilesRole` created by
  the stack to mount it.

---

## Setup

1. **Configure.** Copy the example and fill in your values:

   ```bash
   cp config.env.example config.env
   $EDITOR config.env      # set AWS_ACCOUNT, AWS_PROFILE, S3_FILES_FS_ID, ...
   ```

   `config.env` is git-ignored — your account ID and filesystem ID never get
   committed.

2. **Install script deps** (for the local shell helpers):

   ```bash
   cd scripts && npm install && cd ..
   ```

3. **Deploy** — one command does everything (CDK → frontend → MicroVM image →
   launch → smoke test):

   ```bash
   ./scripts/deploy.sh
   ```

   First run takes ~10 minutes (most of it building the MicroVM image). It
   prints the CloudFront URL and an auto-generated login password (also stored
   in SSM at `/ipad-claude/password`).

4. **Open the CloudFront URL**, log in with any email and that password.

### Deploy flags

| Flag | Effect |
|---|---|
| *(none)* | Full deploy: CDK + frontend + image build + fresh MicroVM |
| `--skip-cdk` | Reuse the existing stack; rebuild image + relaunch |
| `--skip-image` | Reuse the existing image; just relaunch the MicroVM |
| `--skip-mvm` | Deploy infra/image but don't launch a new MicroVM |
| `--recreate-image` | Delete + recreate the image (needed to change OS capabilities) |

---

## Operations

Deploying is the only script you need for normal use — once `deploy.sh`
finishes, everything runs from the browser. The helpers in `tools/` are
optional break-glass utilities for reaching *into* a running MicroVM (which has
no SSH; access is over the service ingress connectors). They read
`AWS_PROFILE` / `AWS_REGION` from your environment — export them (or `source
config.env`) first:

```bash
export AWS_PROFILE=your-profile AWS_REGION=us-east-1
cd tools && npm install && cd ..   # first time only (installs the `ws` client)
```

- **Interactive shell into the MicroVM** (SSH-equivalent, over SHELL_INGRESS):

  ```bash
  node tools/exec.js            # drops to the `coder` user (zsh)
  node tools/exec.js --root     # stay root (system changes don't persist)
  ```

  Double `Ctrl+C` to disconnect.

- **Run a one-off command in the MicroVM** (non-interactive — handy for scripting
  or quick inspection):

  ```bash
  node tools/run-remote.js 'uname -a' 60      # command, optional timeout (sec)
  ```

- **Logs / debugging:** `cat /tmp/hooks.log` inside the MicroVM shows the S3
  Files mount attempts; app logs are in CloudWatch under
  `/aws/lambda-microvms/<image-name>`.

---

## Security

This project is designed as a **single-user sandbox**. Be deliberate before
exposing it more broadly:

- **Single shared password.** One password (in SSM) gates the whole terminal.
  There are no user accounts. Anyone with the URL and password gets a root-
  capable shell (the `coder` user has passwordless `sudo`).
- **Broad AWS privileges.** The MicroVM runs as `MicroVmExecutionRole`, which
  has **`PowerUserAccess`** — full access to AWS services *except* IAM and
  Organizations management. Anything Claude (or anyone in the terminal) runs can
  use those credentials, resolved automatically from the instance role via
  IMDS. Scope this down in `cdk/lib/stack.ts` (`MicroVmExecutionRole`) to only
  the services your sandbox needs before using it anywhere shared.
- **Bedrock spend.** The sandbox can call Bedrock freely; there's no budget cap
  wired in. Add one if you're worried about runaway usage.
- **No network isolation of the workload.** The MicroVM has open outbound
  internet by default.

For a real multi-user deployment you'd want per-user auth, a scoped-down
execution role, per-session MicroVMs, and spend controls — none of which are
here.

---

## Repo layout

```
cdk/                 CDK app (VPC, IAM, buckets, token Lambda, CloudFront, connector)
  bin/app.ts         entry — account/region from env
  lib/stack.ts       the stack
  lambda/token-vend/ token-vending Lambda (SigV4, MicroVM lifecycle)
frontend/index.html  the xterm.js terminal + login screen
microvm/             MicroVM image
  Dockerfile         AL2023 + Node/Python/uv/AWS CLI/Claude Code
  entrypoint.sh      mounts S3 Files, seeds defaults, starts terminal.js
  terminal.js        WebSocket PTY server (ttyd protocol)
  hooks.js           lifecycle hooks (unmount on suspend/terminate, warmup)
  zshrc / bashrc     seeded shell config
scripts/
  deploy.sh          end-to-end deploy (the one script you run)
tools/               optional break-glass utilities for a running MicroVM
  exec.js / exec.sh  interactive local shell into the MicroVM
  run-remote.js      non-interactive remote command runner
config.env.example   copy to config.env and fill in
```

---

## License

[MIT-0](LICENSE) — MIT No Attribution.

This is a personal project and is not an official AWS or Anthropic product.
