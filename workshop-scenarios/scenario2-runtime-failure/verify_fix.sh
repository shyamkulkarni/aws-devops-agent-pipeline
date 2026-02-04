#!/bin/bash
# =============================================================================
# Scenario 2: Verify Fix - Runtime Failure (Missing Environment Variable)
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
echo -e "${BLUE}║  Scenario 2: Verify Fix - Runtime Failure                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: Verify EXTERNAL_API_KEY check removed from code
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: EXTERNAL_API_KEY Check Removed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
if [ -f "$CONTROLLER" ]; then
    if grep -q "EXTERNAL_API_KEY" "$CONTROLLER"; then
        echo -e "${RED}   ✗ EXTERNAL_API_KEY check still present in code${NC}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}   ✓ EXTERNAL_API_KEY check removed from code${NC}"
        PASSED=$((PASSED + 1))
    fi
else
    echo -e "${RED}   ✗ SearchController.java not found${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 2: Service Health Check
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
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
    echo -e "   HTTP Status: ${CYAN}$HTTP_CODE${NC}"
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "${GREEN}   ✓ Service responding with HTTP 200${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}   ✗ Service returned HTTP $HTTP_CODE${NC}"
        FAILED=$((FAILED + 1))
    fi
else
    echo -e "${YELLOW}   ⚠️  ALB not found - deployment may be in progress${NC}"
fi

# =============================================================================
# Check 3: No errors in recent logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 3: CloudWatch Logs${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ERROR_COUNT=$(aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "EXTERNAL_API_KEY" \
    --start-time $(($(date +%s) * 1000 - 300000)) \
    --region $AWS_REGION \
    --query 'events | length(@)' --output text 2>/dev/null || echo "0")

if [ "$ERROR_COUNT" == "0" ] || [ "$ERROR_COUNT" == "None" ]; then
    echo -e "${GREEN}   ✓ No EXTERNAL_API_KEY errors in last 5 minutes${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}   ✗ Found $ERROR_COUNT EXTERNAL_API_KEY errors in logs${NC}"
    FAILED=$((FAILED + 1))
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
