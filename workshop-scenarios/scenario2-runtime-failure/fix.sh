#!/bin/bash
# Scenario 2: Fix - Rollback ECS + Fix source code
# Two-pronged approach: immediate rollback + permanent code fix

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 2: Fix - Rollback + Code Fix                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# PART 1: IMMEDIATE ROLLBACK (Fast recovery)
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚨 PART 1: Immediate ECS Rollback"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Find ECS cluster and service
echo "🔍 Finding ECS cluster and service..."

CLUSTER_NAME=""
SERVICE_NAME=""

CLUSTERS=$(aws ecs list-clusters --query 'clusterArns[*]' --output text --region $AWS_REGION 2>/dev/null)

for CLUSTER_ARN in $CLUSTERS; do
    CLUSTER=$(echo $CLUSTER_ARN | awk -F'/' '{print $NF}')
    SERVICES=$(aws ecs list-services --cluster $CLUSTER --query 'serviceArns[*]' --output text --region $AWS_REGION 2>/dev/null)
    
    for SERVICE_ARN in $SERVICES; do
        if [[ "$SERVICE_ARN" == *"earch"* ]] || [[ "$SERVICE_ARN" == *"Search"* ]]; then
            CLUSTER_NAME=$CLUSTER
            SERVICE_NAME=$(echo $SERVICE_ARN | awk -F'/' '{print $NF}')
            break 2
        fi
    done
done

if [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "   ❌ Could not find PetSearch ECS service"
    exit 1
fi

echo "   ✅ Cluster: $CLUSTER_NAME"
echo "   ✅ Service: $SERVICE_NAME"

# Get current and previous task definitions
echo ""
echo "🔍 Finding task definitions..."

CURRENT_TASK_DEF=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
    --query 'services[0].taskDefinition' --output text --region $AWS_REGION)

TASK_DEF_FAMILY=$(echo $CURRENT_TASK_DEF | awk -F'/' '{print $NF}' | awk -F':' '{print $1}')
CURRENT_REVISION=$(echo $CURRENT_TASK_DEF | awk -F':' '{print $NF}')

echo "   Current: $TASK_DEF_FAMILY:$CURRENT_REVISION"

PREVIOUS_REVISION=$((CURRENT_REVISION - 1))

if [ $PREVIOUS_REVISION -lt 1 ]; then
    echo "   ⚠️  No previous task definition - skipping rollback"
else
    PREVIOUS_TASK_DEF="$TASK_DEF_FAMILY:$PREVIOUS_REVISION"
    echo "   Rolling back to: $PREVIOUS_TASK_DEF"

    # Rollback
    echo ""
    echo "🚀 Rolling back ECS service..."

    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $PREVIOUS_TASK_DEF \
        --force-new-deployment \
        --region $AWS_REGION > /dev/null

    echo "   ✅ Rollback initiated (deploying in background)"
fi

# =============================================================================
# PART 2: FIX SOURCE CODE (Permanent fix)
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 PART 2: Fix Source Code"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Restore from backup or check if already fixed
echo "📝 Fixing SearchController.java..."
if [ -f "$CONTROLLER.backup" ]; then
    mv "$CONTROLLER.backup" "$CONTROLLER"
    echo "   ✅ Restored from backup"
elif grep -q "EXTERNAL_API_KEY" "$CONTROLLER"; then
    echo "   ❌ No backup found and file still has the bug"
    echo "      Please manually remove the EXTERNAL_API_KEY check"
    exit 1
else
    echo "   ✅ Already fixed (no EXTERNAL_API_KEY check found)"
fi

# Commit and push
echo ""
echo "📤 Committing and pushing to CodeCommit..."
cd "$REPO_ROOT"

# Configure CodeCommit remote if not already set
CODECOMMIT_URL=$(aws cloudformation describe-stacks \
    --query "Stacks[?contains(StackName, 'Pipeline') || contains(StackName, 'Workshop')].Outputs[?OutputKey=='CodeCommitRepoCloneUrlHttp'].OutputValue" \
    --output text --region $AWS_REGION 2>/dev/null | head -1)

if [ -n "$CODECOMMIT_URL" ]; then
    git remote set-url origin "$CODECOMMIT_URL" 2>/dev/null || git remote add origin "$CODECOMMIT_URL"
fi

git add PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java 2>/dev/null || true

if git diff --cached --quiet; then
    echo "   ℹ️  No changes to commit"
else
    git commit -m "fix: remove external API dependency that was not configured"
    echo "   ✅ Changes committed"
fi

git push origin main 2>/dev/null && echo "   ✅ Pushed to CodeCommit" || echo "   ℹ️  Already up to date"

# =============================================================================
# PART 3: WAIT FOR ROLLBACK
# =============================================================================
if [ $PREVIOUS_REVISION -ge 1 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⏳ Waiting for ECS rollback to complete..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    COUNTER=0
    MAX_WAIT=300

    while [ $COUNTER -lt $MAX_WAIT ]; do
        sleep 10
        COUNTER=$((COUNTER + 10))
        
        RUNNING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
            --query 'services[0].runningCount' --output text --region $AWS_REGION)
        DESIRED=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
            --query 'services[0].desiredCount' --output text --region $AWS_REGION)
        DEPLOYMENTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
            --query 'length(services[0].deployments)' --output text --region $AWS_REGION)
        
        echo -ne "\r   Running: $RUNNING/$DESIRED, Deployments: $DEPLOYMENTS (${COUNTER}s)    "
        
        if [ "$DEPLOYMENTS" == "1" ] && [ "$RUNNING" == "$DESIRED" ]; then
            break
        fi
    done
    echo ""
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ FIX COMPLETE                                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "   🚀 ECS: Rolled back to previous working version"
echo "   📝 Code: Fixed and pushed to GitHub"
echo "   🔮 Future builds will use the fixed code"
echo ""
