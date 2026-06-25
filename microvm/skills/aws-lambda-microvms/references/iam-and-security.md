# IAM and security

Lambda MicroVMs uses two IAM roles with a clean separation between **build time** and **runtime**, plus auth tokens for ingress traffic.

## Two roles, two phases

| Role | Required? | Used by | Used during |
|---|---|---|---|
| **Build role** (`buildRoleArn`) | Yes | `CreateMicroVmImage` / `UpdateMicroVmImage` | Image build (download artifact, run Dockerfile, ship build logs) |
| **Execution role** (`executionRoleArn`) | Optional | `RunMicroVm` | Application runtime (assumed inside the guest, exposed via IMDSv2) |

The two **must be separate** ARNs in production. The build role usually needs S3/ECR permissions you don't want exposed to running application code; the execution role usually needs application-specific perms (DynamoDB, Secrets Manager, etc.) the build doesn't.

## Trust policy (both roles)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "aws:SourceAccount": "<account-id>"
      },
      "ArnLike": {
        "aws:SourceArn": "arn:aws:lambda:<region>:<account-id>:microvm-image/*"
      }
    }
  }]
}
```

The `Condition` block prevents the confused deputy problem by restricting which Lambda resources can assume these roles.

## Build role — minimum permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCodeArtifact",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::my-bucket/microvm-images/*"
    },
    {
      "Sid": "WriteBuildLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:<region>:<account-id>:log-group:/aws/lambda-microvms/*"
    }
  ]
}
```

Add as needed:

- `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` if your `Dockerfile`'s `FROM` references private ECR.

## Execution role — minimum permissions

The execution role is **optional**, but without it, application stdout is *not* forwarded to CloudWatch.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ],
    "Resource": "arn:aws:logs:<region>:<account-id>:log-group:/aws/lambda-microvms/*"
  }]
}
```

Add scoped permissions for any AWS APIs your application calls (DynamoDB, S3, Secrets Manager, etc.).

The credentials are exposed to the guest via IMDSv2 at:

```
http://169.254.169.254/latest/meta-data/iam/security-credentials/execution_role
```

> Most AWS SDKs pick this up automatically via the default credential chain. **No need to bake credentials into env vars.**

The MicroVM ID is automatically provided in the `/run` hook request body as `microVmId`, alongside any `runPayload` you passed to `RunMicroVm`.

## Auth tokens

Lambda issues short-lived, opaque auth tokens for ingress traffic.

| Field | Detail |
|---|---|
| TTL | `expirationInMinutes` ≤ 60 |
| Header | `X-aws-proxy-auth: <token>` (or WebSocket subprotocol `lambda-microvms.authentication.<token>`) |
| Scope | Restricted to a list of ports/ranges via `allowedPorts` on `CreateMicroVmAuthToken` (required) |

### Two token operations

| Operation | When to use |
|---|---|
| `create-micro-vm-auth-token` | Application traffic. Requires `allowedPorts`. |
| `create-micro-vm-shell-auth-token` | Interactive shell access (browser or terminal). Only works when the MicroVM was run with the `SHELL_INGRESS` network connector attached. |

## Shell access (debugging)

Attach the `SHELL_INGRESS` network connector at run time:

```bash
aws lambda-micro-vms run-micro-vm \
  --image-identifier my-image \
  --execution-role-arn ... \
  --ingress-network-connectors '["arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:SHELL_INGRESS"]'
```

Then `create-micro-vm-shell-auth-token` and connect via the AWS console (Connect button on the MicroVM detail page) or a WebSocket client. The shell drops you into the container where your application runs.

## SCP enforcement and IAM scoping

The caller's IAM role must have `lambda:PassNetworkConnector` allowed on the network connector resource ARN to attach it to a MicroVM.

### Example: allow attaching a specific VPC connector

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "lambda:PassNetworkConnector",
    "Resource": "arn:aws:lambda:<region>:<account>:network-connector:approved-vpc"
  }]
}
```

## PrivateLink

VPC endpoints are supported for the `*.lambda-microvm.on.aws` domain (endpoint service: `com.amazonaws.<region>.lambda-microvm`) — clients in your VPC can reach MicroVM endpoints without traversing the public internet. Standard VPCE policy condition keys apply (`aws:SourceVpce`, `aws:SourceVpc`, `aws:ResourceAccount`, `aws:ResourceOrgID`). See the [AWS PrivateLink security best practices](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html) for guidance on scoping VPCE policies.

## CloudTrail

Standard `lambda:*` data plane and management events show up in CloudTrail.
