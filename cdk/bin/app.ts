#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { IpadClaudeStack } from '../lib/stack';

const app = new cdk.App();

new IpadClaudeStack(app, 'IpadClaudeStack', {
  env: {
    account: '088483494489',
    region: 'us-east-1',
  },
  description: 'iPad Claude Code sandbox — Lambda MicroVM + CloudFront frontend',
});
