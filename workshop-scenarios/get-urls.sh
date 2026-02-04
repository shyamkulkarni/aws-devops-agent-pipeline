#!/bin/bash
# =============================================================================
# Get PetStore Application URLs
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

AWS_REGION="${AWS_REGION:-us-east-1}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              PetStore Application URLs                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get all ALBs
PETSITE=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `PetSi`)].DNSName' --output text 2>/dev/null | head -1)

PETSEARCH=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `searc`)].DNSName' --output text 2>/dev/null | head -1)

PETLIST=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `lista`)].DNSName' --output text 2>/dev/null | head -1)

PAYFOR=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `payfo`)].DNSName' --output text 2>/dev/null | head -1)

TRAFFIC=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?contains(LoadBalancerName, `traff`)].DNSName' --output text 2>/dev/null | head -1)

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  PetSite (Main UI):${NC}"
[ -n "$PETSITE" ] && echo -e "    http://$PETSITE" || echo "    Not found"
echo ""
echo -e "${GREEN}  PetSearch API:${NC}"
[ -n "$PETSEARCH" ] && echo -e "    http://$PETSEARCH/api/search?pettype=puppy" || echo "    Not found"
echo ""
echo -e "${GREEN}  PetListAdoptions:${NC}"
[ -n "$PETLIST" ] && echo -e "    http://$PETLIST" || echo "    Not found"
echo ""
echo -e "${GREEN}  PayForAdoption:${NC}"
[ -n "$PAYFOR" ] && echo -e "    http://$PAYFOR" || echo "    Not found"
echo ""
echo -e "${GREEN}  Traffic Generator:${NC}"
[ -n "$TRAFFIC" ] && echo -e "    http://$TRAFFIC" || echo "    Not found"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Quick health check
echo -e "${BLUE}Quick Health Check:${NC}"
if [ -n "$PETSEARCH" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$PETSEARCH/api/search?pettype=puppy" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "  PetSearch API: ${GREEN}✓ HTTP 200${NC}"
    else
        echo -e "  PetSearch API: ❌ HTTP $HTTP_CODE"
    fi
fi

if [ -n "$PETSITE" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$PETSITE" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "  PetSite UI:    ${GREEN}✓ HTTP 200${NC}"
    else
        echo -e "  PetSite UI:    ❌ HTTP $HTTP_CODE"
    fi
fi
echo ""
