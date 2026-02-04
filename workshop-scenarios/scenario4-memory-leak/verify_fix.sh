#!/bin/bash
# =============================================================================
# Scenario 4: Verify Fix - Memory Leak (Unbounded Cache)
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
echo -e "${BLUE}║  Scenario 4: Verify Fix - Memory Leak                            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: Unbounded cache code removed
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: Unbounded Cache Code Removed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
if [ -f "$CONTROLLER" ]; then
    if grep -q "searchResultCache\|requestPayloadHistory" "$CONTROLLER"; then
        echo -e "${RED}   ✗ Cache variables still present in code${NC}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}   ✓ Unbounded cache code removed${NC}"
        PASSED=$((PASSED + 1))
    fi
else
    echo -e "${RED}   ✗ SearchController.java not found${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 2: Service Health
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 2: Service Health${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALB_URL=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' \
    --output text 2>/dev/null | head -1)

if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    echo -e "   ALB URL: ${CYAN}$ALB_URL${NC}"
    
    SUCCESS=0
    for i in {1..5}; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" == "200" ]; then
            SUCCESS=$((SUCCESS + 1))
        fi
    done
    
    echo -e "   Successful requests: ${CYAN}$SUCCESS/5${NC}"
    
    if [ $SUCCESS -eq 5 ]; then
        echo -e "${GREEN}   ✓ Service responding normally${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}   ✗ Some requests failed${NC}"
        FAILED=$((FAILED + 1))
    fi
else
    echo -e "${YELLOW}   ⚠️  ALB not found${NC}"
fi

# =============================================================================
# Check 3: No cache growth logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 3: No Cache Growth Logs${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CACHE_LOGS=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "Cache size" \
    --start-time $(($(date +%s) * 1000 - 300000)) \
    --region $AWS_REGION \
    --query 'events | length(@)' --output text 2>/dev/null || echo "0")

if [ "$CACHE_LOGS" == "0" ] || [ "$CACHE_LOGS" == "None" ]; then
    echo -e "${GREEN}   ✓ No cache growth logs in last 5 minutes${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}   ⚠️  Found $CACHE_LOGS cache logs (may be from before fix)${NC}"
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
    echo -e "${YELLOW}   💡 Memory metrics will stabilize over time${NC}"
else
    echo -e "${YELLOW}   ⚠️  Some checks failed or pending${NC}"
fi
echo ""
