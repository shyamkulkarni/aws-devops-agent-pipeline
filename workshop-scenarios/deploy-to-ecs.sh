#!/bin/bash
# =============================================================================
# Deploy to ECS - Uses CodeBuild to build and deploy PetSearch service
# =============================================================================
# This script triggers CodeBuild to build the image and then deploys to ECS
# No local Docker required!
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
PIPELINE_NAME="${PIPELINE_NAME:-DevOpsAgent-Pipeline-Workshop-Pipeline-0NHaleIMiheT}"

# Load config if exists
if [ -f "$SCRIPT_DIR/.workshop-config" ]; then
    source "$SCRIPT_DIR/.workshop-config"
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Deploy PetSearch Service to ECS                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Find ECS cluster and service
echo -e "${CYAN}🔍 Step 1: Finding ECS cluster and service...${NC}"

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
    echo -e "${RED}❌ Could not find PetSearch ECS service${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Cluster: $CLUSTER_NAME${NC}"
echo -e "${GREEN}   ✓ Service: $SERVICE_NAME${NC}"

# Step 2: Get current task definition and ECR info
echo ""
echo -e "${CYAN}🔍 Step 2: Getting task definition and ECR repository...${NC}"

TASK_DEF_ARN=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
    --query 'services[0].taskDefinition' --output text --region $AWS_REGION)

# Get container image from task definition
CONTAINER_IMAGE=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN \
    --query 'taskDefinition.containerDefinitions[?name!=`aws-otel-collector`].image' \
    --output text --region $AWS_REGION | head -1)

ECR_REPO=$(echo $CONTAINER_IMAGE | awk -F':' '{print $1}')

echo -e "${GREEN}   ✓ Task Definition: $(echo $TASK_DEF_ARN | awk -F'/' '{print $NF}')${NC}"
echo -e "${GREEN}   ✓ ECR Repository: $ECR_REPO${NC}"

# Step 3: Trigger CodePipeline to build new image
echo ""
echo -e "${CYAN}🔨 Step 3: Triggering CodePipeline build...${NC}"

EXECUTION_ID=$(aws codepipeline start-pipeline-execution \
    --name $PIPELINE_NAME \
    --region $AWS_REGION \
    --query 'pipelineExecutionId' \
    --output text 2>/dev/null)

if [ -z "$EXECUTION_ID" ]; then
    echo -e "${RED}❌ Failed to start pipeline. Check pipeline name.${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Pipeline execution started: $EXECUTION_ID${NC}"

# Step 4: Wait for build to complete
echo ""
echo -e "${CYAN}⏳ Step 4: Waiting for build to complete...${NC}"
echo -e "${YELLOW}   This typically takes 3-5 minutes...${NC}"

BUILD_STATUS="InProgress"
COUNTER=0
MAX_WAIT=600  # 10 minutes

while [ "$BUILD_STATUS" == "InProgress" ] && [ $COUNTER -lt $MAX_WAIT ]; do
    sleep 10
    COUNTER=$((COUNTER + 10))
    
    BUILD_STATUS=$(aws codepipeline get-pipeline-state \
        --name $PIPELINE_NAME \
        --region $AWS_REGION \
        --query 'stageStates[?stageName==`Build`].latestExecution.status' \
        --output text 2>/dev/null)
    
    echo -ne "\r   Build status: $BUILD_STATUS (${COUNTER}s elapsed)    "
done

echo ""

if [ "$BUILD_STATUS" != "Succeeded" ]; then
    echo -e "${RED}❌ Build failed or timed out. Status: $BUILD_STATUS${NC}"
    echo -e "${YELLOW}   Check CodeBuild logs for details.${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Build completed successfully!${NC}"

# Step 5: Get the latest image from ECR
echo ""
echo -e "${CYAN}🔍 Step 5: Getting latest image from ECR...${NC}"

ECR_REPO_NAME=$(echo $ECR_REPO | awk -F'/' '{print $NF}')

LATEST_IMAGE_TAG=$(aws ecr describe-images \
    --repository-name $ECR_REPO_NAME \
    --region $AWS_REGION \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
    --output text 2>/dev/null)

if [ -z "$LATEST_IMAGE_TAG" ] || [ "$LATEST_IMAGE_TAG" == "None" ]; then
    LATEST_IMAGE_TAG="latest"
fi

FULL_IMAGE_URI="$ECR_REPO:$LATEST_IMAGE_TAG"
echo -e "${GREEN}   ✓ Latest image: $FULL_IMAGE_URI${NC}"

# Step 6: Create new task definition with updated image
echo ""
echo -e "${CYAN}📝 Step 6: Creating new task definition...${NC}"

# Save task definition to temp file
TEMP_FILE="/tmp/task-def-$$.json"

aws ecs describe-task-definition --task-definition $TASK_DEF_ARN \
    --query 'taskDefinition' --region $AWS_REGION > $TEMP_FILE

# Update the image in the task definition using a temp file approach
UPDATED_FILE="/tmp/task-def-updated-$$.json"

cat $TEMP_FILE | jq --arg IMAGE "$FULL_IMAGE_URI" '
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
    .containerDefinitions = [.containerDefinitions[] | if .name != "aws-otel-collector" then .image = $IMAGE else . end]
' > $UPDATED_FILE

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file://$UPDATED_FILE \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text --region $AWS_REGION)

rm -f $TEMP_FILE $UPDATED_FILE

echo -e "${GREEN}   ✓ New Task Definition: $(echo $NEW_TASK_DEF_ARN | awk -F'/' '{print $NF}')${NC}"

# Step 7: Update ECS service
echo ""
echo -e "${CYAN}🚀 Step 7: Updating ECS service...${NC}"

aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --task-definition $NEW_TASK_DEF_ARN \
    --force-new-deployment \
    --region $AWS_REGION > /dev/null

echo -e "${GREEN}   ✓ ECS service update initiated${NC}"

# Step 8: Wait for deployment
echo ""
echo -e "${CYAN}⏳ Step 8: Waiting for ECS deployment...${NC}"
echo -e "${YELLOW}   This typically takes 2-5 minutes...${NC}"

COUNTER=0
MAX_WAIT=300

while [ $COUNTER -lt $MAX_WAIT ]; do
    sleep 10
    COUNTER=$((COUNTER + 10))
    
    RUNNING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].runningCount' --output text --region $AWS_REGION)
    DESIRED=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].desiredCount' --output text --region $AWS_REGION)
    PENDING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].pendingCount' --output text --region $AWS_REGION)
    
    echo -ne "\r   Running: $RUNNING/$DESIRED, Pending: $PENDING (${COUNTER}s elapsed)    "
    
    # Check if deployment is stable
    DEPLOYMENTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'length(services[0].deployments)' --output text --region $AWS_REGION)
    
    if [ "$DEPLOYMENTS" == "1" ] && [ "$RUNNING" == "$DESIRED" ]; then
        break
    fi
done

echo ""
echo ""

# Final status
RUNNING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
    --query 'services[0].runningCount' --output text --region $AWS_REGION)
DESIRED=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
    --query 'services[0].desiredCount' --output text --region $AWS_REGION)

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "   Cluster: ${CYAN}$CLUSTER_NAME${NC}"
echo -e "   Service: ${CYAN}$SERVICE_NAME${NC}"
echo -e "   Running: ${CYAN}$RUNNING / $DESIRED${NC}"
echo -e "   Image:   ${CYAN}$FULL_IMAGE_URI${NC}"
echo ""
echo -e "${YELLOW}📋 Next steps:${NC}"
echo "   1. Check CloudWatch logs:"
echo "      aws logs tail /ecs/PetSearch --since 5m --region $AWS_REGION"
echo ""
echo "   2. Run observe script:"
echo "      ./observe-issue.sh"
echo ""
