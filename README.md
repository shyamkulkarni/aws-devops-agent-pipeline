# One Observability Demo

> **Note:** This repository is a fork of [https://github.com/aws-samples/one-observability-demo](https://github.com/aws-samples/one-observability-demo) with additional DevOps Agent integration scenarios.

This repo contains a sample application which is used in the One Observability Demo workshop here - https://observability.workshop.aws/

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

---

# DevOps Agent Pipeline Integration Lab

This lab demonstrates how AWS DevOps Agent integrates with GitHub to detect code changes, receive deployment events, and correlate them with operational incidents.

---

## Prerequisites

Before starting this lab, ensure you have:

- **AWS Account** with Administrator access
- **AWS CLI v2** installed and configured
- **Git** installed locally
- **GitHub Account** with a repository for this workshop

### Verify Prerequisites

```bash
# Check AWS CLI is installed and configured
aws --version
aws sts get-caller-identity

# Check Git is installed
git --version
```

---

## Part 1: Deploy the Infrastructure

### Step 1.1: Create a CodeStar Connection to GitHub

Before deploying, you need a CodeStar Connection to allow AWS to access your GitHub repository:

1. Go to AWS Console → **Developer Tools** → **Settings** → **Connections**
2. Click **Create connection**
3. Select **GitHub** as the provider
4. Click **Connect to GitHub** and authorize AWS
5. Name your connection (e.g., `github-workshop`)
6. Click **Connect**
7. Copy the **Connection ARN** - you'll need it for deployment

### Step 1.2: Fork/Clone This Repository to GitHub

Push this code to your GitHub repository:

```bash
# If you haven't already, push to your GitHub repo
git remote add github https://github.com/YOUR_USERNAME/YOUR_REPO.git
git push github main
```

### Step 1.3: Deploy the CodePipeline Stack

Deploy the infrastructure using AWS CloudFormation:

```bash
aws cloudformation create-stack \
  --stack-name OneObservabilityWorkshop \
  --template-body file://codepipeline-stack.yaml \
  --parameters \
    ParameterKey=CodeStarConnectionArn,ParameterValue="YOUR_CODESTAR_CONNECTION_ARN" \
    ParameterKey=GitHubRepoOwner,ParameterValue="YOUR_GITHUB_USERNAME" \
    ParameterKey=GitHubRepoName,ParameterValue="YOUR_REPO_NAME" \
    ParameterKey=GitHubBranch,ParameterValue="main" \
    ParameterKey=UserRoleArn,ParameterValue="arn:aws:iam::YOUR_ACCOUNT_ID:role/Admin" \
  --capabilities CAPABILITY_IAM
```

Replace the following values:
- `YOUR_CODESTAR_CONNECTION_ARN` - from Step 1.1
- `YOUR_GITHUB_USERNAME` - your GitHub username or organization
- `YOUR_REPO_NAME` - your repository name
- `YOUR_ACCOUNT_ID` - your AWS account ID

Monitor the stack creation:

```bash
aws cloudformation describe-stacks --stack-name OneObservabilityWorkshop \
  --query 'Stacks[0].StackStatus' --output text
```

The pipeline will automatically trigger and deploy the Services stack. Total deployment takes approximately **60-90 minutes**.

### Step 1.4: Verify Application URLs

After deployment completes, get the application URLs:

```bash
# Get all service URLs from the Services stack
aws cloudformation describe-stacks --stack-name Services \
  --query 'Stacks[0].Outputs[?contains(OutputKey, `URL`) || contains(OutputKey, `Url`)].{Key:OutputKey,Value:OutputValue}' \
  --output table
```

This will display:
- **PetSiteUrl** - Main web UI
- **searchserviceecsserviceServiceURL** - Search service
- **listadoptionsserviceecsserviceServiceURL** - Adoption listing service
- **payforadoptionserviceecsserviceServiceURL** - Payment service
- **trafficgeneratorserviceecsserviceServiceURL** - Load generator

### Step 1.5: Save Configuration

```bash
# Get the pipeline name
PIPELINE_NAME=$(aws cloudformation describe-stacks \
    --stack-name DevOpsAgent-Pipeline-Workshop \
    --region us-east-1 \
    --query "Stacks[0].Outputs[?OutputKey=='PipelineName'].OutputValue" \
    --output text)

# Save configuration for later use
cat > .workshop-config << EOF
export STACK_NAME="DevOpsAgent-Pipeline-Workshop"
export AWS_REGION="us-east-1"
export PIPELINE_NAME="$PIPELINE_NAME"
EOF

echo "Configuration saved to .workshop-config"
```

---

## Part 2: Set Up DevOps Agent Integration

DevOps Agent needs to be connected to your AWS resources and CodePipeline to correlate code changes with operational incidents.

### Step 2.1: Open DevOps Agent Console

1. Open the AWS Console
2. Search for **"Amazon Q Developer"** in the search bar
3. Click on **Amazon Q Developer**
4. In the left navigation, click **DevOps Agent**

### Step 2.2: Add GitHub Integration

1. Click **Capabilities** in the left menu
2. Click **Pipeline**
3. Click **Add** button
4. Select **GitHub** as the source
5. Select your repository
6. Click **Save**

### Step 2.3: Verify Integration

1. Go back to **DevOps Agent** → **Capabilities** → **Pipeline**
2. You should see your GitHub repository listed with status **Connected**

---

## Part 3: Run the Scenarios

Before running any scenario, make sure to load your configuration:

```bash
# Load your saved configuration
source .workshop-config

# Verify the variables are set
echo "Pipeline: $PIPELINE_NAME"
echo "Region: $AWS_REGION"
```

---

### Scenario 1: Build Failure

A developer adds a caching library that pulls in incompatible servlet dependencies.

```bash
# Inject the issue (auto-commits, pushes to GitHub, triggers pipeline)
./workshop-scenarios/scenario1-build-failure/inject.sh

# Wait for pipeline to fail, then investigate with DevOps Agent

# After investigating, fix it (auto-commits, pushes, triggers pipeline)
./workshop-scenarios/scenario1-build-failure/fix.sh
```

**Investigation Prompt:**
```
The PetSearch service build is failing with strange errors about
servlet classes. The error mentions jakarta.servlet but also
javax.servlet. What's causing this conflict?
```

---

### Scenario 2: Runtime Failure

A developer adds code requiring an environment variable that doesn't exist.

```bash
# Inject the issue (auto-commits, pushes, triggers pipeline)
./workshop-scenarios/scenario2-runtime-failure/inject.sh

# Wait for deployment, then observe 500 errors with DevOps Agent

# After investigating, fix it
./workshop-scenarios/scenario2-runtime-failure/fix.sh
```

**Investigation Prompt:**
```
The PetSearch service is returning 500 errors after a recent deployment.
Investigate if the code changes are related.
```

---

### Scenario 3: Security Issue

A developer accidentally commits code that logs sensitive data.

```bash
# Inject the issue
./workshop-scenarios/scenario3-security-issue/inject.sh

# Wait for deployment, then analyze CloudWatch logs

# After investigating, fix it
./workshop-scenarios/scenario3-security-issue/fix.sh
```

**Investigation Prompt:**
```
Review CloudWatch logs for the PetSearch service to check if any sensitive 
information like passwords or credentials are being logged.
```

---

### Scenario 4: Memory Leak ⭐

A developer adds caching without eviction policy, causing memory to grow unbounded.

```bash
# Inject the issue
./workshop-scenarios/scenario4-memory-leak/inject.sh

# Wait for deployment, generate traffic, observe memory growth

# After investigating, fix it
./workshop-scenarios/scenario4-memory-leak/fix.sh
```

**Investigation Prompt:**
```
The PetSearch service memory usage has been steadily increasing since 
the last deployment. The service is now experiencing OutOfMemoryError 
crashes. Investigate the recent code changes to identify what might 
be causing the memory leak.
```

---

### Scenario 5: Database Bottleneck / N+1 Query ⭐

A developer adds a feature that makes synchronous database calls inside a loop.

```bash
# Inject the issue
./workshop-scenarios/scenario5-database-bottleneck/inject.sh

# Wait for deployment, observe slow response times

# After investigating, fix it
./workshop-scenarios/scenario5-database-bottleneck/fix.sh
```

**Investigation Prompt:**
```
The PetSearch service response times have increased from 200ms to over 
5 seconds since the last deployment. We're also seeing DynamoDB 
throttling errors. Investigate the recent code changes to identify 
what's causing the performance degradation.
```

---

### Scenario 6: Race Condition / Intermittent Failures ⭐⭐

A developer adds analytics tracking using non-thread-safe collections.

```bash
# Inject the issue
./workshop-scenarios/scenario6-race-condition/inject.sh

# Wait for deployment, send concurrent traffic, observe random 500 errors

# After investigating, fix it
./workshop-scenarios/scenario6-race-condition/fix.sh
```

**Investigation Prompt:**
```
We're seeing intermittent 500 errors on the PetSearch service. About 10% 
of requests fail with different exceptions each time: 
ConcurrentModificationException and NullPointerException. The errors 
started after a recent deployment but we cannot reproduce them locally. 
Investigate the recent code changes to identify potential thread-safety issues.
```

---

## Scenario Summary

| Scenario | Issue Type | Build | Runtime | Symptoms | Detection |
|----------|-----------|-------|---------|----------|-----------|
| 1 | Build Failure | ❌ | N/A | Build fails immediately | Build logs |
| 2 | Runtime Failure | ✅ | ❌ | 500 errors on startup | CloudWatch logs |
| 3 | Security Issue | ✅ | ✅ | Credentials in code | Code review |
| 4 | Memory Leak | ✅ | ⚠️ Degrades | OOM after hours/days | Memory metrics |
| 5 | N+1 Query | ✅ | ⚠️ Slow | 5s+ response times | Latency metrics |
| 6 | Race Condition | ✅ | ⚠️ Random | 5-15% random 500 errors | Error patterns |

**Legend:** ✅ Success | ❌ Failure | ⚠️ Degraded performance

---

## Cleanup

When you're done with the lab, clean up all resources:

```bash
# Load configuration
source .workshop-config

# Delete the main stack (takes 10-15 minutes)
aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $AWS_REGION
echo "Stack deleted!"
```

---

## Troubleshooting

**Pipeline doesn't trigger on push:**
- Verify the CodeStar Connection is in `AVAILABLE` status
- Check that the GitHub webhook was created
- Manually trigger: `aws codepipeline start-pipeline-execution --name $PIPELINE_NAME`

**CodeStar Connection stuck in PENDING:**
- Go to AWS Console → Developer Tools → Connections
- Click on your connection and complete the GitHub authorization

**Build fails with Gradle version error:**
- Ensure `PetAdoptions/petsearch-java/Dockerfile` uses `gradle:7.6-jdk17`

**Reload configuration:**
```bash
source .workshop-config
```
