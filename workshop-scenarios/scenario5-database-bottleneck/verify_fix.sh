#!/bin/bash
# =============================================================================
# Scenario 5: Verify Fix - Database Bottleneck (N+1 Query)
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
echo -e "${BLUE}║  Scenario 5: Verify Fix - Database Bottleneck                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: N+1 query code removed
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: N+1 Query Code Removed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
if [ -f "$CONTROLLER" ]; then
    if grep -q "enrichPetWithAdditionalData" "$CONTROLLER"; then
        echo -e "${RED}   ✗ N+1 query code still present${NC}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}   ✓ N+1 query code removed${NC}"
        PASSED=$((PASSED + 1))
    fi
else
    echo -e "${RED}   ✗ SearchController.java not found${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 2: Response Time Test
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 2: Response Time${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALB_URL=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' \
    --output text 2>/dev/null | head -1)

if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    echo -e "   ALB URL: ${CYAN}$ALB_URL${NC}"
    
    TOTAL_TIME=0
    SUCCESS=0
    
    for i in {1..5}; do
        START=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s%3N)
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
        END=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s%3N)
        DURATION=$((END - START))
        
        if [ "$HTTP_CODE" == "200" ]; then
            SUCCESS=$((SUCCESS + 1))
            TOTAL_TIME=$((TOTAL_TIME + DURATION))
            echo -e "   Request $i: ${CYAN}${DURATION}ms${NC}"
        fi
    done
    
    if [ $SUCCESS -gt 0 ]; then
        AVG=$((TOTAL_TIME / SUCCESS))
        echo ""
        echo -e "   Average: ${CYAN}${AVG}ms${NC}"
        
        if [ $AVG -lt 2000 ]; then
            echo -e "${GREEN}   ✓ Response times healthy (< 2 seconds)${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}   ✗ Response times still elevated${NC}"
            FAILED=$((FAILED + 1))
        fi
    fi
else
    echo -e "${YELLOW}   ⚠️  ALB not found${NC}"
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
