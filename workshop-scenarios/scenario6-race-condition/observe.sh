#!/bin/bash
# =============================================================================
# Scenario 6: Observe Symptoms - Race Condition / Thread-Safety Issues
# =============================================================================
# This script demonstrates the intermittent failures caused by non-thread-safe
# HashMap and ArrayList usage under concurrent load
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
echo -e "${BLUE}║  Scenario 6: Observing Race Condition Symptoms                   ║${NC}"
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
# Step 2: Send concurrent traffic to trigger race condition
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Sending Concurrent Traffic (to trigger race condition)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Sending 50 concurrent requests to trigger thread-safety issues...${NC}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0
ERRORS=""

# Send concurrent requests using background processes
for i in {1..50}; do
    (
        PETTYPE=$(echo "puppy kitten bunny" | tr ' ' '\n' | shuf -n 1)
        HTTP_CODE=$(curl -s -o /tmp/response_$i.txt -w "%{http_code}" \
            "http://$ALB_URL/api/search?pettype=$PETTYPE" 2>/dev/null)
        echo "$HTTP_CODE" > /tmp/status_$i.txt
    ) &
done

# Wait for all requests to complete
wait

# Count results
for i in {1..50}; do
    if [ -f /tmp/status_$i.txt ]; then
        CODE=$(cat /tmp/status_$i.txt)
        if [ "$CODE" == "200" ]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
        rm -f /tmp/status_$i.txt /tmp/response_$i.txt
    fi
done

echo -e "   Results from 50 concurrent requests:"
echo -e "     ${GREEN}✓ Successful (200): $SUCCESS_COUNT${NC}"
echo -e "     ${RED}✗ Failed (500):     $FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    ERROR_RATE=$((FAIL_COUNT * 100 / 50))
    echo -e "${RED}   🔴 Error rate: ${ERROR_RATE}% - Race condition detected!${NC}"
else
    echo -e "${YELLOW}   ⚠️  No failures in this batch. Race conditions are intermittent.${NC}"
    echo -e "${YELLOW}      Try running again or increase concurrent requests.${NC}"
fi

# =============================================================================
# Step 3: Check CloudWatch Logs for thread-safety errors
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking CloudWatch Logs for Thread-Safety Errors${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Searching for ConcurrentModificationException...${NC}"

CME_ERRORS=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "ConcurrentModificationException" \
    --start-time $(($(date +%s) * 1000 - 600000)) \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -3)

if [ -n "$CME_ERRORS" ] && [ "$CME_ERRORS" != "None" ]; then
    echo -e "${RED}   🔴 Found ConcurrentModificationException:${NC}"
    echo ""
    echo "$CME_ERRORS" | head -200
else
    echo -e "${GREEN}   ✓ No ConcurrentModificationException found in recent logs${NC}"
fi

echo ""
echo -e "${YELLOW}   Searching for NullPointerException...${NC}"

NPE_ERRORS=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "NullPointerException" \
    --start-time $(($(date +%s) * 1000 - 600000)) \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -3)

if [ -n "$NPE_ERRORS" ] && [ "$NPE_ERRORS" != "None" ]; then
    echo -e "${RED}   🔴 Found NullPointerException:${NC}"
    echo ""
    echo "$NPE_ERRORS" | head -200
else
    echo -e "${GREEN}   ✓ No NullPointerException found in recent logs${NC}"
fi

# =============================================================================
# Step 4: Check source code for thread-unsafe patterns
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 4: Checking Source Code for Thread-Unsafe Patterns${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo ""
echo -e "   Checking SearchController.java for non-thread-safe collections..."
echo ""

if grep -q "new HashMap<>()" "$CONTROLLER" 2>/dev/null; then
    echo -e "${RED}   🔴 Found non-thread-safe HashMap:${NC}"
    grep -n "new HashMap<>()" "$CONTROLLER" | head -5 | while read line; do
        echo -e "      $line"
    done
fi

if grep -q "new ArrayList<>()" "$CONTROLLER" 2>/dev/null; then
    echo -e "${RED}   🔴 Found non-thread-safe ArrayList:${NC}"
    grep -n "new ArrayList<>()" "$CONTROLLER" | head -5 | while read line; do
        echo -e "      $line"
    done
fi

if grep -q "requestCountByPetType" "$CONTROLLER" 2>/dev/null; then
    echo ""
    echo -e "${RED}   🔴 Found shared mutable state (requestCountByPetType):${NC}"
    grep -n "requestCountByPetType" "$CONTROLLER" | head -5 | while read line; do
        echo -e "      $line"
    done
fi

if grep -q "trackSearchAnalytics" "$CONTROLLER" 2>/dev/null; then
    echo ""
    echo -e "${RED}   🔴 Found analytics tracking method (thread-unsafe):${NC}"
    grep -n "trackSearchAnalytics" "$CONTROLLER" | head -3 | while read line; do
        echo -e "      $line"
    done
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
echo -e "${YELLOW}⚠️  Runtime:${NC} Intermittent failures (5-15% error rate under load)"
echo ""
echo -e "${YELLOW}📋 Root Cause:${NC}"
echo "   The code uses non-thread-safe HashMap and ArrayList for"
echo "   'analytics tracking'. Under concurrent load, multiple threads"
echo "   access these collections simultaneously, causing:"
echo "   • ConcurrentModificationException (iterating while modifying)"
echo "   • NullPointerException (corrupted internal state)"
echo ""
echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
echo ""
echo -e "   ${CYAN}\"We're seeing intermittent 500 errors on the PetSearch service.${NC}"
echo -e "   ${CYAN}About 10% of requests fail with different exceptions each time:${NC}"
echo -e "   ${CYAN}ConcurrentModificationException and NullPointerException.${NC}"
echo -e "   ${CYAN}The errors started after a recent deployment but we cannot${NC}"
echo -e "   ${CYAN}reproduce them locally. Investigate the recent code changes${NC}"
echo -e "   ${CYAN}to identify potential thread-safety issues.\"${NC}"
echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
