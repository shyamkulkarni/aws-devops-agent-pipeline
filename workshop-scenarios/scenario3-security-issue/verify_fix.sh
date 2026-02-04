#!/bin/bash
# =============================================================================
# Scenario 3: Verify Fix - Security Issue (Hardcoded Credentials)
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
echo -e "${BLUE}║  Scenario 3: Verify Fix - Security Issue                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: Secrets file removed
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: Secrets File Removed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

SECRETS_FILE="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/resources/application-secrets.properties"
if [ -f "$SECRETS_FILE" ]; then
    echo -e "${RED}   ✗ Secrets file still exists: application-secrets.properties${NC}"
    FAILED=$((FAILED + 1))
else
    echo -e "${GREEN}   ✓ Secrets file removed${NC}"
    PASSED=$((PASSED + 1))
fi

# =============================================================================
# Check 2: No hardcoded credentials in code
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 2: No Hardcoded Credentials${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

FOUND_SECRETS=$(grep -r "aws_access_key_id\|aws_secret_access_key\|AKIA" \
    "$REPO_ROOT/PetAdoptions/petsearch-java/src" 2>/dev/null | grep -v ".backup" | wc -l || echo "0")

if [ "$FOUND_SECRETS" -eq 0 ]; then
    echo -e "${GREEN}   ✓ No hardcoded AWS credentials found${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}   ✗ Found $FOUND_SECRETS potential hardcoded credentials${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 3: Service still works
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 3: Service Health${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALB_URL=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' \
    --output text 2>/dev/null | head -1)

if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "${GREEN}   ✓ Service responding with HTTP 200${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}   ✗ Service returned HTTP $HTTP_CODE${NC}"
        FAILED=$((FAILED + 1))
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
