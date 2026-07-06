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

- An AWS account with **Bedrock model access enabled** for whichever Claude
  models you want to use. The default is Opus 4.8, but it runs on any Bedrock
  Claude model — enable Haiku 4.5 alone if you want the cheapest option, and set
  it as the default (see `microvm/terminal.js` / the seeded shell config).
- **AWS Lambda MicroVMs** available in your region (this project uses
  `us-east-1`). MicroVMs are a newer capability — make sure your account/region
  has access.
- Local tooling: **AWS CLI v2**, **Node.js 20+**. Docker is *not* required — the
  MicroVM image is built server-side by the build service.

The CDK stack provisions everything else, including the **S3 Files filesystem**
and its VPC mount targets (the persistent `/home/coder`). You don't create it by
hand. (If you'd rather point at an existing filesystem, set `S3_FILES_FS_ID` in
`config.env` and the stack will reference it instead of creating one.)

---

## Deploy — the three stages

The system has three deployable layers, and it's worth understanding each one
before reaching for the script. Configure first, then walk the stages. (There's
a one-command script at the end — but do it by hand once; that's the point of
this repo.)

**Configure.** Copy the example and fill in your values:

```bash
cp config.env.example config.env
$EDITOR config.env       # AWS_ACCOUNT, AWS_PROFILE, region, ...
source config.env        # export the vars for the commands below
```

`config.env` is git-ignored, so your account ID never gets committed. The
commands below assume `$AWS_PROFILE`, `$AWS_REGION`, `$AWS_ACCOUNT`, and
`$IMAGE_NAME` are exported from it. `S3_FILES_FS_ID` is optional — leave it blank
and Stage 1 creates the filesystem; set it to reuse an existing one.

### Stage 1 — Infrastructure (CDK)

Provisions the VPC, security group, the three S3 buckets, all IAM roles, the
token-vending Lambda + API Gateway, CloudFront, and the VPC-egress network
connector. The S3 Files filesystem ID is passed in as context (the stack
references it; it does not create it — see Prerequisites).

```bash
cd cdk
npm install

# One-time per account/region: create the CDK toolkit stack.
CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT CDK_DEFAULT_REGION=$AWS_REGION \
  npx cdk bootstrap "aws://$AWS_ACCOUNT/$AWS_REGION" --profile "$AWS_PROFILE"

# Deploy the stack. This CREATES the S3 Files filesystem + mount targets (plus
# everything else). To reuse an existing filesystem instead, add
# `-c s3FilesFileSystemId=fs-...`.
CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT CDK_DEFAULT_REGION=$AWS_REGION \
  npx cdk deploy IpadClaudeStack \
  --profile "$AWS_PROFILE" \
  --require-approval never \
  --outputs-file /tmp/ipad-claude-outputs.json
cd ..
```

The outputs file now holds the bucket names, role ARNs, the token API URL, the
CloudFront URL, the network connector ARN, and the S3 Files filesystem id that
the next two stages need.
Read them back with, e.g.:

```bash
aws cloudformation describe-stacks --stack-name IpadClaudeStack \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs" --output table
```

### Stage 2 — Frontend (S3 + CloudFront)

The frontend is one static `index.html`. It ships with a `__TOKEN_API_URL__`
placeholder; substitute the real token API URL from Stage 1's outputs, upload to
the frontend bucket, and invalidate the CDN.

```bash
# Helper: pull any stack output by key.
out() { aws cloudformation describe-stacks --stack-name IpadClaudeStack \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

TOKEN_API_URL=$(out TokenApiUrl)
FRONTEND_BUCKET=$(out FrontendBucketName)
CF_DIST_ID=$(out CloudFrontDistributionId)

# Inject the token API URL, then upload.
sed "s|__TOKEN_API_URL__|$TOKEN_API_URL|g" frontend/index.html > /tmp/index.html
aws s3 cp /tmp/index.html "s3://$FRONTEND_BUCKET/index.html" --profile "$AWS_PROFILE"

# Bust the CloudFront cache so the new page is served immediately.
aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" \
  --paths "/*" --profile "$AWS_PROFILE"
```

### Stage 3 — MicroVM image + launch

Two steps: build the image (zip the `microvm/` dir → upload to the artifact
bucket → create/update the MicroVM image), then run a MicroVM from it.

```bash
# (uses the out() helper from Stage 2)
BUILD_ROLE=$(out BuildRoleArn)
EXECUTION_ROLE=$(out ExecutionRoleArn)
ARTIFACT_BUCKET=$(out ArtifactBucketName)
NETWORK_CONNECTOR_ARN=$(out NetworkConnectorArn)
S3_FILES_FS_ID=$(out S3FilesFileSystemId)   # the stack created this in Stage 1

# 3a. Package the image source (substitute the FS ID placeholder first) and upload.
sed "s|__S3_FILES_FS_ID__|$S3_FILES_FS_ID|" microvm/Dockerfile > /tmp/Dockerfile.built
cp /tmp/Dockerfile.built microvm/Dockerfile
(cd microvm && zip -r /tmp/ipad-claude-microvm.zip . -x "*.DS_Store")
aws s3 cp /tmp/ipad-claude-microvm.zip "s3://$ARTIFACT_BUCKET/ipad-claude-microvm.zip" \
  --profile "$AWS_PROFILE"

# 3b. Create the MicroVM image. --additional-os-capabilities '["ALL"]' grants
#     CAP_SYS_ADMIN (needed to mount S3 Files) and ONLY applies at create time.
#     Hooks let the app mount/unmount around lifecycle transitions.
aws lambda-microvms create-microvm-image \
  --name "$IMAGE_NAME" \
  --base-image-arn "arn:aws:lambda:$AWS_REGION:aws:microvm-image:al2023-1" \
  --build-role-arn "$BUILD_ROLE" \
  --code-artifact "{\"uri\":\"s3://$ARTIFACT_BUCKET/ipad-claude-microvm.zip\"}" \
  --additional-os-capabilities '["ALL"]' \
  --hooks '{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":180},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":10,"resume":"ENABLED","resumeTimeoutInSeconds":10,"suspend":"ENABLED","suspendTimeoutInSeconds":10,"terminate":"ENABLED","terminateTimeoutInSeconds":10}}' \
  --environment-variables "{\"S3_FILES_FS_ID\":\"$S3_FILES_FS_ID\"}" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"

# Wait until the image state is CREATED (poll get-microvm-image); ~5-10 min.
IMAGE_ARN="arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT:microvm-image:$IMAGE_NAME"
aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --query state

# 3c. Launch a MicroVM. Ingress connectors expose HTTP (the terminal) and SHELL
#     (the tools/ helpers); the egress connector reaches the S3 Files mount targets.
aws lambda-microvms run-microvm \
  --image-identifier "$IMAGE_ARN" \
  --execution-role-arn "$EXECUTION_ROLE" \
  --idle-policy '{"maxIdleDurationSeconds":1800,"suspendedDurationSeconds":600,"autoResumeEnabled":true}' \
  --maximum-duration-in-seconds 28800 \
  --ingress-network-connectors "[\"arn:aws:lambda:$AWS_REGION:aws:network-connector:aws-network-connector:HTTP_INGRESS\",\"arn:aws:lambda:$AWS_REGION:aws:network-connector:aws-network-connector:SHELL_INGRESS\"]" \
  --egress-network-connectors "[\"$NETWORK_CONNECTOR_ARN\"]" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

The `run-microvm` response includes the `microvmId` and `endpoint`. The token
Lambda finds the running VM via SSM parameters, so store them:

```bash
# (use the microvmId / endpoint from the run-microvm output)
aws ssm put-parameter --name /ipad-claude/mvm-identifier --value "$MVM_ID" \
  --type String --overwrite --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws ssm put-parameter --name /ipad-claude/mvm-endpoint --value "$MVM_ENDPOINT" \
  --type String --overwrite --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Also set the login password once (the token Lambda validates against it):

```bash
aws ssm put-parameter --name /ipad-claude/password --value "choose-a-password" \
  --type SecureString --overwrite --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Now open the CloudFront URL, log in with any email + that password, and you're
in the terminal.

### …or just run the script

Once you understand the stages, `scripts/deploy.sh` does all of the above
end-to-end (it also auto-generates the password on first run, polls the image
build, terminates the previous MicroVM, and smoke-tests the result):

```bash
./scripts/deploy.sh
```

| Flag | Effect |
|---|---|
| *(none)* | Full deploy: Stage 1 + 2 + 3 |
| `--skip-cdk` | Skip Stage 1; rebuild image + relaunch (Stage 3) |
| `--skip-image` | Skip the image build; just relaunch the MicroVM (Stage 3c) |
| `--skip-mvm` | Do Stages 1–2 and the image build, but don't launch a MicroVM |
| `--recreate-image` | Delete + recreate the image (required to change OS capabilities) |

> **Updating an existing image** uses `aws lambda-microvms update-microvm-image`
> with the *same* flags as create — capabilities, hooks, and env vars reset to
> defaults unless you re-pass them every time. Changing OS capabilities requires
> a delete + recreate (`--recreate-image`), since `--additional-os-capabilities`
> only applies at create time.

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
