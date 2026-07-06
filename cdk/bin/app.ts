#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { IpadClaudeStack } from '../lib/stack';

const app = new cdk.App();

// Account/region come from the standard CDK env vars (set by deploy.sh from
// config.env, or by your shell / `aws configure`). Region defaults to us-east-1.
new IpadClaudeStack(app, 'IpadClaudeStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'us-east-1',
  },
  description: 'iPad Claude Code sandbox — Lambda MicroVM + CloudFront frontend',
});
