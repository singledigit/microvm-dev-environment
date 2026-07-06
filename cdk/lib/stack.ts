import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import { Construct } from 'constructs';
import * as path from 'path';

export class IpadClaudeStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);

    const account = this.account;
    const region = this.region;

    // S3 Files filesystem: this stack CREATES it (see below). To reuse an
    // existing filesystem instead, pass its id via `-c s3FilesFileSystemId=fs-...`
    // (deploy.sh forwards S3_FILES_FS_ID from config.env when set).
    const existingS3FilesId = this.node.tryGetContext('s3FilesFileSystemId')
      || process.env.S3_FILES_FS_ID;

    // ── VPC for S3 Files mount targets ───────────────────────────────────────
    const vpc = new ec2.Vpc(this, 'MicroVmVpc', {
      vpcName: 'ipad-claude-vpc',
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        { name: 'public',  subnetType: ec2.SubnetType.PUBLIC,           cidrMask: 24 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });

    // Security group allowing NFS (2049) within the VPC
    const nfsSg = new ec2.SecurityGroup(this, 'NfsSg', {
      vpc,
      securityGroupName: 'ipad-claude-nfs',
      description: 'Allow NFS traffic for S3 Files mount targets',
    });
    nfsSg.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(2049), 'NFS from VPC');

    // ── S3: workspace bucket (mounted into MicroVM via S3 Files) ─────────────
    const workspaceBucket = new s3.Bucket(this, 'WorkspaceBucket', {
      bucketName: `ipad-claude-workspace-${account}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ── IAM: S3 Files service role (assumed by S3 Files to access the bucket) ─
    // Trust principal is elasticfilesystem.amazonaws.com (S3 Files is built on EFS)
    const s3FilesRole = new iam.Role(this, 'S3FilesRole', {
      roleName: 'IpadClaudeS3FilesRole',
      assumedBy: new iam.ServicePrincipal('elasticfilesystem.amazonaws.com', {
        conditions: {
          StringEquals: { 'aws:SourceAccount': account },
          ArnLike: { 'aws:SourceArn': `arn:aws:s3files:${region}:${account}:file-system/*` },
        },
      }),
      inlinePolicies: {
        BucketAccess: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                's3:ListBucket', 's3:ListBucketVersions',
              ],
              resources: [workspaceBucket.bucketArn],
              conditions: { StringEquals: { 'aws:ResourceAccount': account } },
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                's3:AbortMultipartUpload',
                's3:DeleteObject', 's3:DeleteObjectVersion',
                's3:GetObject', 's3:GetObjectVersion',
                's3:List*',
                's3:PutObject', 's3:PutObjectAcl',
              ],
              resources: [`${workspaceBucket.bucketArn}/*`],
              conditions: { StringEquals: { 'aws:ResourceAccount': account } },
            }),
            // EventBridge rules for S3 bucket change detection
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'events:DeleteRule', 'events:DisableRule', 'events:EnableRule',
                'events:PutRule', 'events:PutTargets', 'events:RemoveTargets',
              ],
              resources: [`arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*`],
              conditions: { StringEquals: { 'events:ManagedBy': 'elasticfilesystem.amazonaws.com' } },
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'events:DescribeRule', 'events:ListRuleNamesByTarget',
                'events:ListRules', 'events:ListTargetsByRule',
              ],
              resources: ['arn:aws:events:*:*:rule/*'],
            }),
          ],
        }),
      },
    });

    // ── S3 Files filesystem + mount targets ──────────────────────────────────
    // S3 Files is built on EFS-style NFS. We create the filesystem (backed by
    // the workspace bucket, synced via the role above) and a mount target ENI
    // in each private subnet so the MicroVM can mount it over NFS (port 2049).
    // Only L1 (Cfn) constructs exist today, so these are raw CfnResources.
    // If `existingS3FilesId` was supplied, we skip creation and reuse it.
    let s3FilesFileSystemId: string;

    if (existingS3FilesId) {
      s3FilesFileSystemId = existingS3FilesId;
    } else {
      const fileSystem = new cdk.CfnResource(this, 'S3FilesFileSystem', {
        type: 'AWS::S3Files::FileSystem',
        properties: {
          Bucket: workspaceBucket.bucketArn,
          RoleArn: s3FilesRole.roleArn,
          // Acknowledge that this bucket is dedicated to S3 Files (it is —
          // WorkspaceBucket exists only for the mounted home directories).
          AcceptBucketWarning: true,
        },
      });
      // The role's bucket + EventBridge permissions must exist before S3 Files
      // tries to sync / install its change-detection rules.
      fileSystem.node.addDependency(s3FilesRole);
      s3FilesFileSystemId = fileSystem.ref;

      // One mount target per private subnet (NFS ENIs), guarded by the NFS SG.
      vpc.privateSubnets.forEach((subnet, i) => {
        new cdk.CfnResource(this, `S3FilesMountTarget${i}`, {
          type: 'AWS::S3Files::MountTarget',
          properties: {
            FileSystemId: s3FilesFileSystemId,
            SubnetId: subnet.subnetId,
            SecurityGroups: [nfsSg.securityGroupId],
          },
        });
      });
    }

    // ── S3: MicroVM artifact bucket ──────────────────────────────────────────
    const artifactBucket = new s3.Bucket(this, 'ArtifactBucket', {
      bucketName: `ipad-claude-artifacts-${account}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ── IAM: MicroVM build role ───────────────────────────────────────────────
    const buildRole = new iam.Role(this, 'MicroVmBuildRole', {
      roleName: 'MicroVmBuildRole',
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com', {
        conditions: {
          StringEquals: { 'aws:SourceAccount': account },
        },
      }),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
      inlinePolicies: {
        ArtifactRead: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:GetObject', 's3:GetObjectVersion'],
              resources: [`${artifactBucket.bucketArn}/*`],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:ListBucket'],
              resources: [artifactBucket.bucketArn],
            }),
          ],
        }),
      },
    });

    // ── IAM: MicroVM execution role (serverless-developer scope + Bedrock) ────
    // PowerUserAccess = full access to AWS services, WITHOUT IAM/Organizations
    // management. This is the credential the sandbox operates with — anything
    // Claude runs in the terminal can use it. Widen or narrow to taste; see the
    // SECURITY section in the README before deploying anywhere shared.
    const executionRole = new iam.Role(this, 'MicroVmExecutionRole', {
      roleName: 'MicroVmExecutionRole',
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com', {
        conditions: {
          StringEquals: { 'aws:SourceAccount': account },
        },
      }),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('PowerUserAccess'),
      ],
      inlinePolicies: {
        BedrockInvoke: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'bedrock:InvokeModel',
                'bedrock:InvokeModelWithResponseStream',
              ],
              resources: [
                `arn:aws:bedrock:${region}::foundation-model/anthropic.claude-*`,
              ],
            }),
            // S3 Files mount permissions
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3files:ClientMount', 's3files:ClientWrite'],
              resources: ['*'],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:GetObject', 's3:GetObjectVersion', 's3:PutObject', 's3:DeleteObject', 's3:ListBucket'],
              resources: [workspaceBucket.bucketArn, `${workspaceBucket.bucketArn}/*`],
            }),
          ],
        }),
      },
    });

    // ── IAM: Token vending Lambda role ────────────────────────────────────────
    const tokenLambdaRole = new iam.Role(this, 'TokenLambdaRole', {
      roleName: 'IpadClaudeTokenLambdaRole',
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
      inlinePolicies: {
        TokenVendPerms: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['ssm:GetParameter', 'ssm:PutParameter'],
              resources: [
                `arn:aws:ssm:${region}:${account}:parameter/ipad-claude/*`,
              ],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['ses:SendEmail', 'ses:SendRawEmail'],
              resources: ['*'],
            }),
            // MicroVM lifecycle + token creation
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['lambda:*'],
              resources: ['*'],
              conditions: {
                StringEquals: { 'aws:RequestedRegion': region },
              },
            }),
            // Pass execution role when launching new MicroVMs
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['iam:PassRole'],
              resources: [
                `arn:aws:iam::${account}:role/MicroVmExecutionRole`,
              ],
            }),
          ],
        }),
      },
    });

    // ── Lambda: token vending function ────────────────────────────────────────
    const tokenFn = new lambda.Function(this, 'TokenFunction', {
      functionName: 'ipad-claude-token-vend',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      role: tokenLambdaRole,
      timeout: cdk.Duration.seconds(30),
      environment: {
        MVM_IDENTIFIER_PARAM: '/ipad-claude/mvm-identifier',
        ALLOWED_ORIGINS: '*',
        IMAGE_ARN: `arn:aws:lambda:${region}:${account}:microvm-image:ipad-claude-v2`,
        EXECUTION_ROLE_ARN: executionRole.roleArn,
        NETWORK_CONNECTOR_ARN: cdk.Lazy.string({ produce: () => networkConnector.getAtt('Arn').toString() }),
      },
      code: lambda.Code.fromAsset(path.join(__dirname, '../lambda/token-vend')),
    });

    // ── API Gateway: token endpoint ───────────────────────────────────────────
    const api = new apigateway.RestApi(this, 'TokenApi', {
      restApiName: 'ipad-claude-token-api',
      description: 'Vends short-lived MicroVM auth tokens',
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: ['GET', 'OPTIONS'],
        allowHeaders: ['Content-Type', 'X-Login-Email', 'X-Login-Password'],
      },
    });

    const tokenResource = api.root.addResource('token');
    tokenResource.addMethod('GET', new apigateway.LambdaIntegration(tokenFn, {
      timeout: cdk.Duration.seconds(29),
    }));

    // ── S3: Frontend hosting bucket ───────────────────────────────────────────
    const frontendBucket = new s3.Bucket(this, 'FrontendBucket', {
      bucketName: `ipad-claude-frontend-${account}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // ── CloudFront: Frontend distribution ────────────────────────────────────
    const oac = new cloudfront.S3OriginAccessControl(this, 'FrontendOAC', {
      description: 'ipad-claude frontend OAC',
    });

    const distribution = new cloudfront.Distribution(this, 'FrontendDistribution', {
      comment: 'iPad Claude Code frontend',
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(frontendBucket, {
          originAccessControl: oac,
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
      },
      defaultRootObject: 'index.html',
      errorResponses: [
        { httpStatus: 403, responseHttpStatus: 200, responsePagePath: '/index.html' },
        { httpStatus: 404, responseHttpStatus: 200, responsePagePath: '/index.html' },
      ],
    });

    // ── IAM: Network connector operator role ─────────────────────────────────
    const networkConnectorRole = new iam.Role(this, 'NetworkConnectorOperatorRole', {
      roleName: 'NetworkConnectorOperatorRole',
      assumedBy: new iam.CompositePrincipal(
        new iam.ServicePrincipal('lambda.amazonaws.com'),
        new iam.ServicePrincipal('network-connectors.lambda.amazonaws.com'),
      ),
      inlinePolicies: {
        ENIManagement: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['ec2:CreateNetworkInterface'],
              resources: [
                `arn:aws:ec2:*:*:network-interface/*`,
                `arn:aws:ec2:*:*:subnet/*`,
                `arn:aws:ec2:*:*:security-group/*`,
              ],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['ec2:CreateTags'],
              resources: [`arn:aws:ec2:*:*:network-interface/*`],
              conditions: {
                StringEquals: {
                  'ec2:ManagedResourceOperator': 'network-connectors.lambda.amazonaws.com',
                },
              },
            }),
          ],
        }),
      },
    });

    // ── Lambda Network Connector (VPC egress for S3 Files mount targets) ──────
    const networkConnector = new cdk.CfnResource(this, 'VpcEgressConnector', {
      type: 'AWS::Lambda::NetworkConnector',
      properties: {
        Name: 'ipad-claude-vpc-egress',
        Configuration: {
          VpcEgressConfiguration: {
            SubnetIds: vpc.privateSubnets.map(s => s.subnetId),
            SecurityGroupIds: [nfsSg.securityGroupId],
            NetworkProtocol: 'IPv4',
            AssociatedComputeResourceTypes: ['MicroVm'],
          },
        },
        OperatorRole: networkConnectorRole.roleArn,
      },
    });
    networkConnector.addDependency(networkConnectorRole.node.defaultChild as cdk.CfnResource);

    // Deploy frontend files
    new s3deploy.BucketDeployment(this, 'FrontendDeploy', {
      sources: [s3deploy.Source.asset(path.join(__dirname, '../../frontend'))],
      destinationBucket: frontendBucket,
      distribution,
      distributionPaths: ['/*'],
    });

    // ── Outputs ───────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ArtifactBucketName', {
      value: artifactBucket.bucketName,
      exportName: 'IpadClaudeArtifactBucket',
    });

    new cdk.CfnOutput(this, 'BuildRoleArn', {
      value: buildRole.roleArn,
      exportName: 'IpadClaudeBuildRoleArn',
    });

    new cdk.CfnOutput(this, 'ExecutionRoleArn', {
      value: executionRole.roleArn,
      exportName: 'IpadClaudeExecutionRoleArn',
    });

    new cdk.CfnOutput(this, 'TokenApiUrl', {
      value: `${api.url}token`,
      exportName: 'IpadClaudeTokenApiUrl',
    });

    new cdk.CfnOutput(this, 'FrontendUrl', {
      value: `https://${distribution.distributionDomainName}`,
      exportName: 'IpadClaudeFrontendUrl',
    });

    new cdk.CfnOutput(this, 'FrontendBucketName', {
      value: frontendBucket.bucketName,
      exportName: 'IpadClaudeFrontendBucket',
    });

    new cdk.CfnOutput(this, 'CloudFrontDistributionId', {
      value: distribution.distributionId,
      exportName: 'IpadCloudeCFDistributionId',
    });

    new cdk.CfnOutput(this, 'WorkspaceBucketName', {
      value: workspaceBucket.bucketName,
      exportName: 'IpadClaudeWorkspaceBucket',
    });

    new cdk.CfnOutput(this, 'WorkspaceBucketArn', {
      value: workspaceBucket.bucketArn,
      exportName: 'IpadClaudeWorkspaceBucketArn',
    });

    new cdk.CfnOutput(this, 'VpcId', {
      value: vpc.vpcId,
      exportName: 'IpadClaudeVpcId',
    });

    new cdk.CfnOutput(this, 'PrivateSubnetIds', {
      value: vpc.privateSubnets.map(s => s.subnetId).join(','),
      exportName: 'IpadClaudePrivateSubnetIds',
    });

    new cdk.CfnOutput(this, 'NfsSgId', {
      value: nfsSg.securityGroupId,
      exportName: 'IpadClaudeNfsSgId',
    });

    new cdk.CfnOutput(this, 'S3FilesRoleArn', {
      value: s3FilesRole.roleArn,
      exportName: 'IpadClaudeS3FilesRoleArn',
    });

    new cdk.CfnOutput(this, 'NetworkConnectorArn', {
      value: networkConnector.getAtt('Arn').toString(),
      exportName: 'IpadClaudeNetworkConnectorArn',
    });

    new cdk.CfnOutput(this, 'S3FilesFileSystemId', {
      value: s3FilesFileSystemId,
      exportName: 'IpadClaudeS3FilesFileSystemId',
    });
  }
}
