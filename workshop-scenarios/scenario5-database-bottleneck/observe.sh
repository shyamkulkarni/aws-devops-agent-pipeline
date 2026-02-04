#!/bin/bash
# =============================================================================
# Scenario 5: Observe Symptoms - Database Bottleneck / N+1 Query
# =============================================================================
# This script demonstrates the performance degradation caused by N+1 queries
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 5: Observing Database Bottleneck Symptoms              ║${NC}"
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
# Step 2: Measure Response Time
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Measuring API Response Time${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Making 5 test requests to measure response time...${NC}"
echo ""

TOTAL_TIME=0
for i in $(seq 1 5); do
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
        "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null)
    
    HTTP_CODE=$(echo $RESPONSE | cut -d',' -f1)
    TIME=$(echo $RESPONSE | cut -d',' -f2)
    TIME_MS=$(echo "$TIME * 1000" | bc 2>/dev/null || echo "0")
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "   Request $i: ${GREEN}$HTTP_CODE${NC} - ${CYAN}${TIME_MS%.*}ms${NC}"
    else
        echo -e "   Request $i: ${RED}$HTTP_CODE${NC} - ${CYAN}${TIME_MS%.*}ms${NC}"
    fi
    
    TOTAL_TIME=$(echo "$TOTAL_TIME + $TIME" | bc 2>/dev/null || echo "0")
done

AVG_TIME=$(echo "scale=2; $TOTAL_TIME / 5 * 1000" | bc 2>/dev/null || echo "0")
echo ""
echo -e "   Average Response Time: ${CYAN}${AVG_TIME%.*}ms${NC}"

if (( $(echo "$AVG_TIME > 3000" | bc -l 2>/dev/null || echo "0") )); then
    echo -e "${RED}   🔴 PERFORMANCE ISSUE: Response time > 3 seconds!${NC}"
    SLOW_RESPONSE=true
else
    echo -e "${GREEN}   ✓ Response time is acceptable${NC}"
    SLOW_RESPONSE=false
fi

# =============================================================================
# Step 3: Check CloudWatch Logs for N+1 Pattern
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking CloudWatch Logs for N+1 Pattern${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

LOG_GROUP="/ecs/PetSearch"
START_TIME=$(($(date +%s) * 1000 - 600000))  # Last 10 minutes

echo ""
echo -e "${MAGENTA}   🔍 Searching for enrichment logs...${NC}"
echo ""

ENRICH_LOGS=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "Enriching" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[-3:].message' --output text 2>/dev/null)

if [ -n "$ENRICH_LOGS" ] && [ "$ENRICH_LOGS" != "None" ]; then
    echo -e "${RED}   🔴 N+1 QUERY PATTERN DETECTED:${NC}"
    echo ""
    echo "$ENRICH_LOGS"
    FOUND_ENRICH=true
else
    FOUND_ENRICH=false
fi

echo ""
echo -e "${MAGENTA}   🔍 Searching for per-pet fetch logs...${NC}"
echo ""

FETCH_LOGS=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "Fetching additional data for pet" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[-10:].message' --output text 2>/dev/null)

if [ -n "$FETCH_LOGS" ] && [ "$FETCH_LOGS" != "None" ]; then
    echo -e "${RED}   🔴 Individual DB calls for each pet:${NC}"
    echo ""
    echo "$FETCH_LOGS" | head -10
    FOUND_FETCH=true
else
    FOUND_FETCH=false
fi

# =============================================================================
# Step 4: Check DynamoDB Metrics
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 4: Checking DynamoDB Metrics${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Find DynamoDB table
TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION \
    --query 'TableNames[?contains(@, `Pet`) || contains(@, `pet`)]' \
    --output text 2>/dev/null | head -1)

if [ -n "$TABLE_NAME" ]; then
    echo ""
    echo -e "   DynamoDB Table: ${CYAN}$TABLE_NAME${NC}"
    echo ""
    
    # Check for throttled requests
    END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    START_TIME_CW=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    THROTTLED=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/DynamoDB" \
        --metric-name "ThrottledRequests" \
        --dimensions Name=TableName,Value=$TABLE_NAME \
        --start-time "$START_TIME_CW" \
        --end-time "$END_TIME" \
        --period 300 \
        --statistics Sum \
        --region $AWS_REGION \
        --query 'Datapoints[*].Sum' \
        --output text 2>/dev/null)
    
    if [ -n "$THROTTLED" ] && [ "$THROTTLED" != "None" ] && [ "$THROTTLED" != "0" ]; then
        echo -e "${RED}   🔴 DynamoDB Throttling Detected!${NC}"
        echo -e "   Throttled Requests: $THROTTLED"
        FOUND_THROTTLE=true
    else
        echo -e "${GREEN}   ✓ No DynamoDB throttling detected${NC}"
        FOUND_THROTTLE=false
    fi
else
    echo -e "${YELLOW}   Could not find DynamoDB table${NC}"
    FOUND_THROTTLE=false
fi

# =============================================================================
# Step 5: Check Source Code for the Issue
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 5: Checking Source Code for N+1 Pattern${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo ""
if grep -q "enrichPetWithAdditionalData" "$CONTROLLER" 2>/dev/null; then
    echo -e "${RED}   🔴 N+1 QUERY PATTERN FOUND in SearchController.java:${NC}"
    echo ""
    echo -e "   The code contains:"
    echo "     - 'enrichPetWithAdditionalData' method called in a loop"
    echo "     - Individual DynamoDB GetItem for each pet"
    echo "     - 100ms artificial delay per pet"
    echo "     - With 50 pets: 50 DB calls + 5 seconds delay"
    FOUND_CODE=true
else
    echo -e "${GREEN}   ✓ No N+1 query pattern found in SearchController.java${NC}"
    FOUND_CODE=false
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                         SUMMARY                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${GREEN}✅ Build:${NC} Succeeded"
echo -e "${GREEN}✅ Deployment:${NC} Succeeded"

if [ "$SLOW_RESPONSE" = true ] || [ "$FOUND_ENRICH" = true ] || [ "$FOUND_CODE" = true ]; then
    echo -e "${RED}❌ Runtime:${NC} Severe performance degradation"
    echo ""
    echo -e "${YELLOW}📋 Root Cause:${NC}"
    echo "   A 'feature enhancement' was added that enriches each pet with"
    echo "   additional data. However, it makes a separate database call for"
    echo "   each pet (N+1 query pattern), causing:"
    echo "     • Response time: 200ms → 5+ seconds"
    echo "     • DynamoDB calls: 1 → 51 per request"
    echo "     • Under load: Connection exhaustion and throttling"
else
    echo -e "${YELLOW}⚠️  Runtime:${NC} Issue may not be visible yet"
    echo ""
    echo -e "${YELLOW}   Note: If you just deployed, wait for the new code to be active.${NC}"
fi

echo ""
echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
echo ""
echo -e "   ${CYAN}\"The PetSearch service response times have increased from 200ms${NC}"
echo -e "   ${CYAN}to over 5 seconds since the last deployment. We're also seeing${NC}"
echo -e "   ${CYAN}DynamoDB throttling errors. Investigate the recent code changes${NC}"
echo -e "   ${CYAN}to identify what's causing the performance degradation.\"${NC}"
echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
