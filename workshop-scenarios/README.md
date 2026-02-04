# DevOps Agent Pipeline Integration Lab

This lab demonstrates how AWS DevOps Agent integrates with CodeCommit to detect code changes, receive deployment events, and correlate them with operational incidents.

---

## Prerequisites

Before starting this lab, ensure you have:

- **AWS Account** with Administrator access
- **AWS CLI v2** installed and configured
- **Git** installed locally

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

### Step 1.1: Run the Deployment Script

The deployment script handles everything automatically:
1. Creates the CloudFormation stack (CodeCommit repo, CodePipeline, ECS, etc.)
2. Waits for stack creation to complete
3. Configures git credentials for CodeCommit
4. Pushes the code to CodeCommit to trigger the pipeline

```bash
# Navigate to the workshop directory
cd one-observability-demo

# Make the script executable (if needed)
chmod +x deploy-workshop.sh

# Run the deployment (~5-10 minutes for stack, then auto-pushes to CodeCommit)
./deploy-workshop.sh
```

The script automatically detects your IAM ARN, so no manual configuration is needed.

### Step 1.2: Wait for Initial Build

The pipeline automatically starts building after the code is pushed. This takes approximately **30-45 minutes**. Monitor progress:

```bash
# Get the pipeline name
PIPELINE_NAME=$(aws cloudformation describe-stacks \
    --stack-name DevOpsAgent-Pipeline-Workshop \
    --region us-east-1 \
    --query "Stacks[0].Outputs[?OutputKey=='PipelineName'].OutputValue" \
    --output text)

echo "Pipeline Name: $PIPELINE_NAME"

# Check pipeline status
aws codepipeline get-pipeline-state \
    --name $PIPELINE_NAME \
    --region us-east-1 \
    --query 'stageStates[*].[stageName,latestExecution.status]' \
    --output table
```

### Step 1.3: Save Configuration

```bash
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

DevOps Agent needs to be connected to your CodeCommit repository to correlate code changes with operational incidents.

### Step 2.1: Open DevOps Agent Console

1. Open the AWS Console
2. Search for **"Amazon Q Developer"** in the search bar
3. Click on **Amazon Q Developer**
4. In the left navigation, click **DevOps Agent**

### Step 2.2: Add CodeCommit Integration

1. Click **Capabilities** in the left menu
2. Click **Pipeline**
3. Click **Add** button
4. Select **CodeCommit** as the source
5. Select the repository: `one-observability-workshop`
6. Click **Save**

### Step 2.3: Verify Integration

1. Go back to **DevOps Agent** → **Capabilities** → **Pipeline**
2. You should see your CodeCommit repository listed with status **Connected**

**Note:** DevOps Agent will now automatically receive:
- Push events (code changes)
- Deployment status from CodePipeline

---

## Part 3: Run the Scenarios

Before running any scenario, make sure to load your configuration:

```bash
# Load your saved configuration (sets PIPELINE_NAME, AWS_REGION, etc.)
source .workshop-config

# Verify the variables are set
echo "Pipeline: $PIPELINE_NAME"
echo "Region: $AWS_REGION"
```

---

### Scenario 1: Build Failure

A developer upgrades Spring Boot without checking Java compatibility.

```bash
# Step 1: Inject the issue (modifies code locally)
./scenario1-build-failure/inject.sh

# Step 2: Commit and push the change
git add -A
git commit -m "chore: upgrade Spring Boot to 3.2.0"
git push origin main

# Step 3: Trigger the pipeline
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION

# Step 4: Wait for pipeline to fail, then investigate with DevOps Agent

# Step 5: After investigating, fix it
./scenario1-build-failure/fix.sh

# Step 6: Commit and push the fix
git add -A
git commit -m "fix: revert Spring Boot to 2.7.3"
git push origin main

# Step 7: Trigger the pipeline again
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION
```

**Investigation Prompt:**
```
The PetSearch service deployment failed. Check the recent code changes 
and identify what caused the build failure.
```

---

### Scenario 2: Runtime Failure

A developer adds code requiring an environment variable that doesn't exist.

```bash
# Step 1: Inject the issue (auto-commits, pushes, and triggers pipeline)
./scenario2-runtime-failure/inject.sh

# Step 2: Wait for deployment to complete, then observe 500 errors with DevOps Agent

# Step 3: After investigating, fix it (auto-commits, pushes, and triggers pipeline)
./scenario2-runtime-failure/fix.sh
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
# Step 1: Inject the issue (auto-commits, pushes, and triggers pipeline)
./scenario3-security-issue/inject.sh

# Step 2: Wait for deployment, then use DevOps Agent to analyze CloudWatch logs for sensitive data

# Step 3: After investigating, fix it (auto-commits, pushes, and triggers pipeline)
./scenario3-security-issue/fix.sh
```

**Investigation Prompt:**
```
Review CloudWatch logs for the PetSearch service to check if any sensitive 
information like passwords or credentials are being logged.
```

---

### Scenario 4: Memory Leak ⭐

A developer adds "performance optimization" caching without eviction policy, causing memory to grow unbounded.

```bash
# Step 1: Inject the issue
./scenario4-memory-leak/inject.sh

# Step 2: Commit and push the change
git add -A
git commit -m "perf: add caching layer for search results"
git push origin main

# Step 3: Trigger the pipeline
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION

# Step 4: Wait for deployment, generate traffic, observe memory growth with DevOps Agent

# Step 5: After investigating, fix it
./scenario4-memory-leak/fix.sh

# Step 6: Commit and push the fix
git add -A
git commit -m "fix: remove unbounded cache causing memory leak"
git push origin main

# Step 7: Trigger the pipeline again
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION
```

**Investigation Prompt:**
```
The PetSearch service memory usage has been steadily increasing since 
the last deployment. The service is now experiencing OutOfMemoryError 
crashes. Investigate the recent code changes to identify what might 
be causing the memory leak.
```

**What DevOps Agent will find:**
- Correlates memory spike timing with deployment timestamp
- Identifies the commit that added 'caching' code
- Points to the static HashMap with no eviction policy
- Recommends using LRU cache or time-based eviction

---

### Scenario 5: Database Bottleneck / N+1 Query ⭐

A developer adds a feature that makes synchronous database calls inside a loop, causing cascading failures under load.

```bash
# Step 1: Inject the issue
./scenario5-database-bottleneck/inject.sh

# Step 2: Commit and push the change
git add -A
git commit -m "feat: enrich pet search results with additional metadata"
git push origin main

# Step 3: Trigger the pipeline
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION

# Step 4: Wait for deployment, observe slow response times with DevOps Agent

# Step 5: After investigating, fix it
./scenario5-database-bottleneck/fix.sh

# Step 6: Commit and push the fix
git add -A
git commit -m "fix: remove N+1 query pattern causing performance issues"
git push origin main

# Step 7: Trigger the pipeline again
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION
```

**Investigation Prompt:**
```
The PetSearch service response times have increased from 200ms to over 
5 seconds since the last deployment. We're also seeing DynamoDB 
throttling errors. Investigate the recent code changes to identify 
what's causing the performance degradation.
```

**What DevOps Agent will find:**
- Correlates latency spike with deployment timestamp
- Identifies the commit that added 'enrichment' code
- Detects the N+1 query pattern in the loop
- Shows trace data revealing sequential DB calls
- Recommends batch fetching or caching strategies

---

### Scenario 6: Race Condition / Intermittent Failures ⭐⭐

A developer adds analytics tracking using non-thread-safe collections, causing random failures under concurrent load.

**Why this matters:** Race conditions are THE hardest bugs to debug because:
- They work fine in dev/test (single user)
- They fail randomly in production (concurrent users)  
- They cannot be reproduced locally
- Error logs show different stack traces each time

```bash
# Step 1: Inject the issue
./scenario6-race-condition/inject.sh

# Step 2: Commit and push the change
git add -A
git commit -m "feat: add search analytics tracking"
git push origin main

# Step 3: Trigger the pipeline
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION

# Step 4: Wait for deployment, send concurrent traffic, observe random 500 errors with DevOps Agent

# Step 5: After investigating, fix it
./scenario6-race-condition/fix.sh

# Step 6: Commit and push the fix
git add -A
git commit -m "fix: remove thread-unsafe analytics"
git push origin main

# Step 7: Trigger the pipeline again
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION
```

**Investigation Prompt:**
```
We're seeing intermittent 500 errors on the PetSearch service. About 10% 
of requests fail with different exceptions each time: 
ConcurrentModificationException and NullPointerException. The errors 
started after a recent deployment but we cannot reproduce them locally. 
Investigate the recent code changes to identify potential thread-safety issues.
```

**What DevOps Agent will find:**
- Correlates error spike timing with deployment
- Identifies the commit that added 'analytics' code
- Detects non-thread-safe HashMap/ArrayList usage
- Points to concurrent read/write patterns
- Recommends ConcurrentHashMap or synchronization

---

## Observing Issues and Verifying Fixes

After injecting a scenario, use these helper scripts to observe symptoms and verify fixes:

### Observe Issue Symptoms

```bash
# Run the observation script
./observe-issue.sh

# Select the scenario number when prompted
# The script will check pipeline status, CloudWatch logs, metrics, etc.
```

### Verify Fix Worked

```bash
# Run the verification script
./verify-fix.sh

# Select the scenario number when prompted
# The script will verify the code changes and test the service
```

---

## Scenario Summary

| Scenario | Issue Type | Build | Runtime | Symptoms | Detection |
|----------|-----------|-------|---------|----------|-----------|
| 1 | Build Failure | ❌ | N/A | Build fails immediately | Build logs |
| 2 | Runtime Failure | ✅ | ❌ | 500 errors on startup | CloudWatch logs |
| 3 | Security Issue | ✅ | ✅ | Credentials in code | Code review |
| 4 | Memory Leak | ✅ | ⚠️ Degrades | OOM after hours/days | Memory metrics + deployment correlation |
| 5 | N+1 Query | ✅ | ⚠️ Slow | 5s+ response times | Latency metrics + trace analysis |
| 6 | Race Condition | ✅ | ⚠️ Random | 5-15% random 500 errors | Error pattern + code analysis |

**Legend:** ✅ Success | ❌ Failure | ⚠️ Degraded performance

---

## Cleanup

When you're done with the lab, clean up all resources to avoid charges:

### Step 1: Load Configuration

```bash
cd workshop-scenarios
source .workshop-config
```

### Step 2: Delete CloudFormation Stack

```bash
# Delete the main stack (this will take 10-15 minutes)
aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION

# Wait for deletion to complete
echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $AWS_REGION
echo "Stack deleted successfully!"
```

### Step 3: Remove DevOps Agent Integration (Optional)

1. Open AWS Console → **Amazon Q Developer** → **DevOps Agent**
2. Go to **Capabilities** → **Pipeline**
3. Select your CodeCommit repository
4. Click **Remove**

---

## Troubleshooting

**Pipeline doesn't trigger on push:**
- Verify the code was pushed to CodeCommit: `git remote -v`
- Manually trigger: `aws codepipeline start-pipeline-execution --name $PIPELINE_NAME`

**Build fails with Gradle version error:**
- Ensure `PetAdoptions/petsearch-java/Dockerfile` uses `gradle:7.6-jdk17`

**Git credential issues with CodeCommit:**
- Re-run the credential helper setup:
  ```bash
  git config --global credential.helper '!aws codecommit credential-helper $@'
  git config --global credential.UseHttpPath true
  ```

**Reload configuration:**
```bash
source workshop-scenarios/.workshop-config
```
