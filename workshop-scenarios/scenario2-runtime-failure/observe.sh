#!/bin/bash
# =============================================================================
# Scenario 2: Observe Symptoms - Missing Environment Variable
# =============================================================================
# This script demonstrates the runtime failure caused by missing EXTERNAL_API_KEY
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

AWS_REGION="${AWS_REGION:-us-east-1}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 2: Observing Runtime Failure Symptoms                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Step 1: Find the PetSearch ALB
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 1: Finding PetSearch Load Balancer${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALB_URL=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' \
    --output text 2>/dev/null | head -1)

if [ -z "$ALB_URL" ]; then
    echo -e "${RED}   ✗ Could not find PetSearch ALB${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ ALB URL: $ALB_URL${NC}"

# =============================================================================
# Step 2: Test the API endpoint
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Testing API Endpoint${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Calling: GET http://$ALB_URL/api/search?pettype=puppy${NC}"
echo ""

HTTP_CODE=$(curl -s -o /tmp/response.json -w "%{http_code}" "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null)

echo -e "   HTTP Status Code: ${RED}$HTTP_CODE${NC}"
echo ""
echo -e "   Response Body:"
cat /tmp/response.json 2>/dev/null | head -5
echo ""

if [ "$HTTP_CODE" == "500" ]; then
    echo -e "${RED}   🔴 API is returning 500 Internal Server Error!${NC}"
else
    echo -e "${YELLOW}   ⚠️  Unexpected status code: $HTTP_CODE${NC}"
fi

# =============================================================================
# Step 3: Check CloudWatch Logs for the error
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking CloudWatch Logs${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Searching for EXTERNAL_API_KEY errors in /ecs/PetSearch...${NC}"
echo ""

ERRORS=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "EXTERNAL_API_KEY" \
    --start-time $(($(date +%s) * 1000 - 300000)) \
    --region $AWS_REGION \
    --query 'events[0].message' --output text 2>/dev/null)

if [ -n "$ERRORS" ] && [ "$ERRORS" != "None" ]; then
    echo -e "${RED}   🔴 Found error in logs:${NC}"
    echo ""
    echo "$ERRORS" | head -500
else
    echo -e "${YELLOW}   No recent EXTERNAL_API_KEY errors found. Checking for RuntimeException...${NC}"
    
    ERRORS=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
        --filter-pattern "Missing required configuration" \
        --start-time $(($(date +%s) * 1000 - 300000)) \
        --region $AWS_REGION \
        --query 'events[0].message' --output text 2>/dev/null)
    
    if [ -n "$ERRORS" ] && [ "$ERRORS" != "None" ]; then
        echo -e "${RED}   🔴 Found error in logs:${NC}"
        echo ""
        echo "$ERRORS" | head -500
    fi
fi

# =============================================================================
# Step 4: Check ECS Task Definition for env vars
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 4: Checking ECS Task Definition Environment Variables${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Find the cluster and service
CLUSTER_NAME=$(aws ecs list-clusters --region $AWS_REGION \
    --query 'clusterArns[?contains(@, `Search`) || contains(@, `Pet`)]' \
    --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}')

if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(aws ecs list-clusters --region $AWS_REGION \
        --query 'clusterArns[0]' --output text 2>/dev/null | awk -F'/' '{print $NF}')
fi

SERVICE_NAME=$(aws ecs list-services --cluster $CLUSTER_NAME --region $AWS_REGION \
    --query 'serviceArns[?contains(@, `earch`) || contains(@, `Search`)]' \
    --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}')

if [ -n "$SERVICE_NAME" ]; then
    TASK_DEF=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --region $AWS_REGION --query 'services[0].taskDefinition' --output text 2>/dev/null)
    
    echo ""
    echo -e "   Task Definition: ${CYAN}$(echo $TASK_DEF | awk -F'/' '{print $NF}')${NC}"
    echo ""
    echo -e "   Environment Variables in container:"
    
    ENV_VARS=$(aws ecs describe-task-definition --task-definition $TASK_DEF --region $AWS_REGION \
        --query 'taskDefinition.containerDefinitions[?name!=`aws-otel-collector`].environment[*].name' \
        --output text 2>/dev/null)
    
    if [ -n "$ENV_VARS" ]; then
        echo "$ENV_VARS" | tr '\t' '\n' | while read var; do
            echo -e "     - $var"
        done
    else
        echo -e "     ${YELLOW}(none configured)${NC}"
    fi
    
    echo ""
    if echo "$ENV_VARS" | grep -q "EXTERNAL_API_KEY"; then
        echo -e "${GREEN}   ✓ EXTERNAL_API_KEY is configured${NC}"
    else
        echo -e "${RED}   ✗ EXTERNAL_API_KEY is NOT configured in task definition!${NC}"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                         SUMMARY                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✅ Build:${NC} Succeeded (code compiles fine)"
echo -e "${GREEN}✅ Deployment:${NC} Succeeded (container is running)"
echo -e "${RED}❌ Runtime:${NC} Failing with 500 errors"
echo ""
echo -e "${YELLOW}📋 Root Cause:${NC}"
echo "   The code checks for EXTERNAL_API_KEY environment variable,"
echo "   but it was never added to the ECS task definition."
echo ""
echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
echo ""
echo -e "   ${CYAN}\"The PetSearch service is returning 500 errors after a recent${NC}"
echo -e "   ${CYAN}deployment. Investigate if the code changes are related.\"${NC}"
echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
