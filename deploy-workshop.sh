#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="DevOpsAgent-Pipeline-Workshop"

echo "=============================================="
echo "One Observability Workshop - GitHub Deployment"
echo "=============================================="
echo ""

# Check for required tools
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI is not installed"
    exit 1
fi

# Get current AWS identity
echo "Checking AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
REGION=$(aws configure get region || echo "us-east-1")

echo "Account: $ACCOUNT_ID"
echo "User/Role: $USER_ARN"
echo "Region: $REGION"
echo ""

# Prompt for GitHub details
echo "=============================================="
echo "GitHub Repository Configuration"
echo "=============================================="
echo ""

read -p "GitHub Repository Owner (username or org): " GITHUB_OWNER
read -p "GitHub Repository Name: " GITHUB_REPO
read -p "GitHub Branch [main]: " GITHUB_BRANCH
GITHUB_BRANCH=${GITHUB_BRANCH:-main}

echo ""
echo "=============================================="
echo "CodeStar Connection"
echo "=============================================="
echo ""
echo "You need a CodeStar Connection to GitHub."
echo "If you don't have one, create it in the AWS Console:"
echo "  Developer Tools -> Settings -> Connections -> Create connection"
echo ""
echo "Available connections:"
aws codestar-connections list-connections --query 'Connections[?ProviderType==`GitHub`].[ConnectionArn,ConnectionName,ConnectionStatus]' --output table 2>/dev/null || echo "  (none found or unable to list)"
echo ""

read -p "CodeStar Connection ARN: " CODESTAR_ARN

if [ -z "$CODESTAR_ARN" ]; then
    echo "ERROR: CodeStar Connection ARN is required"
    exit 1
fi

# Verify connection status
CONNECTION_STATUS=$(aws codestar-connections get-connection --connection-arn "$CODESTAR_ARN" --query 'Connection.ConnectionStatus' --output text 2>/dev/null || echo "UNKNOWN")
if [ "$CONNECTION_STATUS" != "AVAILABLE" ]; then
    echo ""
    echo "WARNING: Connection status is '$CONNECTION_STATUS'"
    echo "The connection must be in 'AVAILABLE' status."
    echo "If it's 'PENDING', complete the connection setup in the AWS Console."
    read -p "Continue anyway? [y/N]: " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        exit 1
    fi
fi

echo ""
echo "=============================================="
echo "Deployment Summary"
echo "=============================================="
echo "Stack Name: $STACK_NAME"
echo "GitHub Repo: $GITHUB_OWNER/$GITHUB_REPO"
echo "Branch: $GITHUB_BRANCH"
echo "CodeStar Connection: $CODESTAR_ARN"
echo "User Role ARN: $USER_ARN"
echo ""

read -p "Deploy stack? [y/N]: " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Deployment cancelled"
    exit 0
fi

echo ""
echo "Deploying CloudFormation stack..."
echo "This will take approximately 60-90 minutes."
echo ""

aws cloudformation deploy \
    --template-file "$SCRIPT_DIR/codepipeline-stack.yaml" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        UserRoleArn="$USER_ARN" \
        GitHubRepoOwner="$GITHUB_OWNER" \
        GitHubRepoName="$GITHUB_REPO" \
        GitHubBranch="$GITHUB_BRANCH" \
        CodeStarConnectionArn="$CODESTAR_ARN"

echo ""
echo "=============================================="
echo "Stack deployment initiated!"
echo "=============================================="
echo ""
echo "The pipeline will now:"
echo "1. Pull source code from GitHub ($GITHUB_OWNER/$GITHUB_REPO)"
echo "2. Build and deploy the PetAdoptions application"
echo ""
echo "Monitor progress:"
echo "  - CloudFormation: https://$REGION.console.aws.amazon.com/cloudformation/home?region=$REGION#/stacks"
echo "  - CodePipeline: https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines"
echo ""
echo "Once complete, run ./workshop-scenarios/get-urls.sh to get application URLs"
