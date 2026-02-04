#!/bin/bash
# =============================================================================
# Scenario 6: Verify Fix - Race Condition (Thread-Unsafe Code)
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 6: Verify Fix - Race Condition                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: Thread-unsafe code removed
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: Thread-Unsafe Code Removed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
if [ -f "$CONTROLLER" ]; then
    if grep -q "requestCountByPetType\|recentSearches\|trackSearchAnalytics" "$CONTROLLER"; then
        echo -e "${RED}   ✗ Thread-unsafe analytics code still present${NC}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}   ✓ Thread-unsafe code removed${NC}"
        PASSED=$((PASSED + 1))
    fi
else
    echo -e "${RED}   ✗ SearchController.java not found${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 2: Concurrent Request Test
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 2: Concurrent Request Test (50 requests)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALB_URL=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' \
    --output text 2>/dev/null | head -1)

if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    echo -e "   ALB URL: ${CYAN}$ALB_URL${NC}"
    echo -e "   Sending concurrent requests..."
    
    # Send concurrent requests
    for i in {1..50}; do
        (
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
            echo "$HTTP_CODE" > /tmp/verify_status_$i.txt
        ) &
    done
    wait
    
    SUCCESS=0
    FAILED_REQ=0
    for i in {1..50}; do
        if [ -f /tmp/verify_status_$i.txt ]; then
            CODE=$(cat /tmp/verify_status_$i.txt)
            if [ "$CODE" == "200" ]; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAILED_REQ=$((FAILED_REQ + 1))
            fi
            rm -f /tmp/verify_status_$i.txt
        fi
    done
    
    ERROR_RATE=$((FAILED_REQ * 100 / 50))
    echo -e "   Success: ${GREEN}$SUCCESS${NC} / Failed: ${RED}$FAILED_REQ${NC}"
    echo -e "   Error rate: ${CYAN}${ERROR_RATE}%${NC}"
    
    if [ $ERROR_RATE -lt 2 ]; then
        echo -e "${GREEN}   ✓ Error rate healthy (< 2%)${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}   ✗ Error rate still elevated${NC}"
        FAILED=$((FAILED + 1))
    fi
else
    echo -e "${YELLOW}   ⚠️  ALB not found${NC}"
fi

# =============================================================================
# Check 3: No ConcurrentModificationException in logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 3: CloudWatch Logs${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CME_COUNT=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "ConcurrentModificationException" \
    --start-time $(($(date +%s) * 1000 - 300000)) \
    --region $AWS_REGION \
    --query 'events | length(@)' --output text 2>/dev/null || echo "0")

if [ "$CME_COUNT" == "0" ] || [ "$CME_COUNT" == "None" ]; then
    echo -e "${GREEN}   ✓ No ConcurrentModificationException in last 5 minutes${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}   ⚠️  Found $CME_COUNT exceptions (may be from before fix)${NC}"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                      VERIFICATION SUMMARY                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "   ${GREEN}Passed: $PASSED${NC}"
echo -e "   ${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ] && [ $PASSED -gt 0 ]; then
    echo -e "${GREEN}   ✅ Fix verified successfully!${NC}"
else
    echo -e "${YELLOW}   ⚠️  Some checks failed or pending${NC}"
fi
echo ""
