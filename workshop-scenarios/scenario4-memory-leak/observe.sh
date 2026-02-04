#!/bin/bash
# =============================================================================
# Scenario 4: Observe Symptoms - Memory Leak
# =============================================================================
# This script demonstrates the memory leak caused by unbounded caching
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
echo -e "${BLUE}║  Scenario 4: Observing Memory Leak Symptoms                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Step 1: Find the PetSearch ALB and generate traffic
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
# Step 2: Generate traffic to trigger memory growth
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Generating Traffic (to trigger memory growth)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Sending 50 requests with unique parameters...${NC}"
echo ""

SUCCESS=0
FAILED=0

for i in $(seq 1 50); do
    # Each request has unique timestamp to create new cache entries
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://$ALB_URL/api/search?pettype=puppy&ts=$i-$(date +%s%N)" 2>/dev/null)
    
    if [ "$HTTP_CODE" == "200" ]; then
        ((SUCCESS++))
    else
        ((FAILED++))
    fi
    
    echo -ne "\r   Progress: $i/50 requests (Success: $SUCCESS, Failed: $FAILED)"
done

echo ""
echo ""
echo -e "${GREEN}   ✓ Traffic generation complete${NC}"
echo -e "   Successful requests: ${GREEN}$SUCCESS${NC}"
echo -e "   Failed requests: ${RED}$FAILED${NC}"

# =============================================================================
# Step 3: Check CloudWatch Logs for cache growth
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking CloudWatch Logs for Cache Growth${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

LOG_GROUP="/ecs/PetSearch"
START_TIME=$(($(date +%s) * 1000 - 600000))  # Last 10 minutes

echo ""
echo -e "${MAGENTA}   🔍 Searching for cache size logs...${NC}"
echo ""

CACHE_LOGS=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "cache size" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[-5:].message' --output text 2>/dev/null)

if [ -n "$CACHE_LOGS" ] && [ "$CACHE_LOGS" != "None" ]; then
    echo -e "${RED}   🔴 MEMORY LEAK INDICATOR: Cache is growing unbounded!${NC}"
    echo ""
    echo "$CACHE_LOGS"
    FOUND_CACHE=true
else
    echo -e "${YELLOW}   No cache size logs found yet${NC}"
    FOUND_CACHE=false
fi

echo ""
echo -e "${MAGENTA}   🔍 Searching for cached queries count...${NC}"
echo ""

CACHED_QUERIES=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "total cached queries" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[-5:].message' --output text 2>/dev/null)

if [ -n "$CACHED_QUERIES" ] && [ "$CACHED_QUERIES" != "None" ]; then
    echo -e "${RED}   🔴 Cache entries growing with each request:${NC}"
    echo ""
    echo "$CACHED_QUERIES"
    FOUND_QUERIES=true
else
    FOUND_QUERIES=false
fi

# =============================================================================
# Step 4: Check ECS Memory Metrics
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 4: Checking ECS Memory Metrics${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Find cluster and service
CLUSTER_NAME=$(aws ecs list-clusters --region $AWS_REGION \
    --query 'clusterArns[0]' --output text 2>/dev/null | awk -F'/' '{print $NF}')

SERVICE_NAME=$(aws ecs list-services --cluster $CLUSTER_NAME --region $AWS_REGION \
    --query 'serviceArns[?contains(@, `earch`) || contains(@, `Search`)]' \
    --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}')

if [ -n "$SERVICE_NAME" ]; then
    echo ""
    echo -e "   Cluster: ${CYAN}$CLUSTER_NAME${NC}"
    echo -e "   Service: ${CYAN}$SERVICE_NAME${NC}"
    echo ""
    
    # Get memory utilization from CloudWatch
    END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    START_TIME_CW=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    MEMORY_UTIL=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/ECS" \
        --metric-name "MemoryUtilization" \
        --dimensions Name=ClusterName,Value=$CLUSTER_NAME Name=ServiceName,Value=$SERVICE_NAME \
        --start-time "$START_TIME_CW" \
        --end-time "$END_TIME" \
        --period 300 \
        --statistics Average \
        --region $AWS_REGION \
        --query 'Datapoints | sort_by(@, &Timestamp) | [-3:].Average' \
        --output text 2>/dev/null)
    
    if [ -n "$MEMORY_UTIL" ] && [ "$MEMORY_UTIL" != "None" ]; then
        echo -e "   Memory Utilization (last 3 data points):"
        echo "$MEMORY_UTIL" | tr '\t' '\n' | while read val; do
            if [ -n "$val" ]; then
                printf "     %.1f%%\n" "$val"
            fi
        done
    else
        echo -e "${YELLOW}   Memory metrics not available yet${NC}"
    fi
fi

# =============================================================================
# Step 5: Check Source Code for the Issue
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 5: Checking Source Code for Memory Leak${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo ""
if grep -q "searchResultCache" "$CONTROLLER" 2>/dev/null; then
    echo -e "${RED}   🔴 MEMORY LEAK FOUND in SearchController.java:${NC}"
    echo ""
    echo -e "   The code contains:"
    echo "     - static HashMap 'searchResultCache' with no size limit"
    echo "     - static List 'requestPayloadHistory' storing 10KB per request"
    echo "     - No cache eviction policy"
    echo "     - Each unique request creates a new cache entry"
    FOUND_CODE=true
else
    echo -e "${GREEN}   ✓ No unbounded cache found in SearchController.java${NC}"
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

if [ "$FOUND_CACHE" = true ] || [ "$FOUND_QUERIES" = true ] || [ "$FOUND_CODE" = true ]; then
    echo -e "${RED}❌ Runtime:${NC} Memory growing unbounded"
    echo ""
    echo -e "${YELLOW}📋 Root Cause:${NC}"
    echo "   A 'performance optimization' was added that caches search results,"
    echo "   but the cache has no eviction policy. Each unique request creates"
    echo "   a new cache entry that is never removed, causing memory to grow"
    echo "   until the service crashes with OutOfMemoryError."
    echo ""
    echo -e "${YELLOW}📋 Timeline:${NC}"
    echo "   • Minutes: Memory usage starts climbing"
    echo "   • Hours: GC pressure increases, response times degrade"
    echo "   • Days: OutOfMemoryError crashes, service restarts"
else
    echo -e "${YELLOW}⚠️  Runtime:${NC} Issue may not be visible yet"
    echo ""
    echo -e "${YELLOW}   Note: Memory leaks take time to manifest.${NC}"
    echo -e "${YELLOW}   Generate more traffic and check again.${NC}"
fi

echo ""
echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
echo ""
echo -e "   ${CYAN}\"The PetSearch service memory usage has been steadily increasing${NC}"
echo -e "   ${CYAN}since the last deployment. The service is now experiencing${NC}"
echo -e "   ${CYAN}OutOfMemoryError crashes. Investigate the recent code changes${NC}"
echo -e "   ${CYAN}to identify what might be causing the memory leak.\"${NC}"
echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
