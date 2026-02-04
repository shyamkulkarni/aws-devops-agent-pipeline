#!/bin/bash
# =============================================================================
# Scenario 3: Observe Symptoms - Sensitive Data in CloudWatch Logs
# =============================================================================
# This script demonstrates the security vulnerability by showing sensitive
# data being logged to CloudWatch
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

AWS_REGION="${AWS_REGION:-us-east-1}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 3: Observing Security Issue - Sensitive Data Logging   ║${NC}"
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
# Step 2: Make a test request to generate logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Making Test Request (with sensitive headers)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${YELLOW}   Calling: GET http://$ALB_URL/api/search?pettype=puppy${NC}"
echo -e "${YELLOW}   With headers: Authorization, X-Api-Key, Cookie${NC}"
echo ""

# Make request with sensitive headers that will be logged
HTTP_CODE=$(curl -s -o /tmp/response.json -w "%{http_code}" \
    -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test-token" \
    -H "X-Api-Key: sk-test-api-key-12345" \
    -H "Cookie: session=abc123; auth_token=secret456" \
    "http://$ALB_URL/api/search?pettype=puppy" 2>/dev/null)

echo -e "   HTTP Status Code: ${GREEN}$HTTP_CODE${NC}"

if [ "$HTTP_CODE" == "200" ]; then
    echo -e "${GREEN}   ✓ API is working - response received${NC}"
else
    echo -e "${YELLOW}   ⚠️  Unexpected status code: $HTTP_CODE${NC}"
fi

# Wait a moment for logs to propagate
echo ""
echo -e "${YELLOW}   Waiting 5 seconds for logs to propagate to CloudWatch...${NC}"
sleep 5

# =============================================================================
# Step 3: Check CloudWatch Logs for sensitive data
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking CloudWatch Logs for Sensitive Data${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

LOG_GROUP="/ecs/PetSearch"
START_TIME=$(($(date +%s) * 1000 - 600000))  # Last 10 minutes

echo ""
echo -e "${YELLOW}   Searching log group: $LOG_GROUP${NC}"
echo ""

# Check for REQUEST HEADERS being logged
echo -e "${MAGENTA}   🔍 Checking for logged HTTP headers...${NC}"
HEADERS_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "REQUEST HEADERS" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -20)

if [ -n "$HEADERS_LOG" ] && [ "$HEADERS_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: HTTP headers are being logged!${NC}"
    echo ""
    echo "$HEADERS_LOG" | head -10
    FOUND_HEADERS=true
else
    echo -e "${GREEN}   ✓ No header logging found${NC}"
    FOUND_HEADERS=false
fi

# Check for Authorization header specifically
echo ""
echo -e "${MAGENTA}   🔍 Checking for Authorization header in logs...${NC}"
AUTH_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "authorization" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -10)

if [ -n "$AUTH_LOG" ] && [ "$AUTH_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: Authorization tokens are being logged!${NC}"
    echo ""
    echo "$AUTH_LOG" | head -5
    FOUND_AUTH=true
else
    echo -e "${GREEN}   ✓ No Authorization header logging found${NC}"
    FOUND_AUTH=false
fi

# Check for INTERNAL RESOURCES being logged
echo ""
echo -e "${MAGENTA}   🔍 Checking for internal AWS resource names...${NC}"
RESOURCES_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "INTERNAL RESOURCES" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -10)

if [ -n "$RESOURCES_LOG" ] && [ "$RESOURCES_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: Internal AWS resources are being logged!${NC}"
    echo ""
    echo "$RESOURCES_LOG" | head -5
    FOUND_RESOURCES=true
else
    echo -e "${GREEN}   ✓ No internal resource logging found${NC}"
    FOUND_RESOURCES=false
fi

# Check for DynamoDB table name
echo ""
echo -e "${MAGENTA}   🔍 Checking for DynamoDB table name in logs...${NC}"
DYNAMO_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "DynamoDB Table" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -5)

if [ -n "$DYNAMO_LOG" ] && [ "$DYNAMO_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: DynamoDB table name is being logged!${NC}"
    echo ""
    echo "$DYNAMO_LOG" | head -3
    FOUND_DYNAMO=true
else
    echo -e "${GREEN}   ✓ No DynamoDB table name logging found${NC}"
    FOUND_DYNAMO=false
fi

# Check for S3 presigned URLs
echo ""
echo -e "${MAGENTA}   🔍 Checking for S3 presigned URLs in logs...${NC}"
S3_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "presigned URL" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -5)

if [ -n "$S3_LOG" ] && [ "$S3_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: S3 presigned URLs are being logged!${NC}"
    echo ""
    echo "$S3_LOG" | head -3
    FOUND_S3=true
else
    echo -e "${GREEN}   ✓ No S3 presigned URL logging found${NC}"
    FOUND_S3=false
fi

# Check for SSM parameter values
echo ""
echo -e "${MAGENTA}   🔍 Checking for SSM parameter values in logs...${NC}"
SSM_LOG=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "SSM parameter" \
    --start-time $START_TIME \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -5)

if [ -n "$SSM_LOG" ] && [ "$SSM_LOG" != "None" ]; then
    echo -e "${RED}   🔴 SECURITY ISSUE: SSM parameter values are being logged!${NC}"
    echo ""
    echo "$SSM_LOG" | head -3
    FOUND_SSM=true
else
    echo -e "${GREEN}   ✓ No SSM parameter logging found${NC}"
    FOUND_SSM=false
fi

# =============================================================================
# Step 4: Check source code for the vulnerability
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 4: Checking Source Code for Vulnerability${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo ""
if grep -q "logRequestDetails" "$CONTROLLER" 2>/dev/null; then
    echo -e "${RED}   🔴 VULNERABILITY FOUND in SearchController.java:${NC}"
    echo ""
    echo -e "${YELLOW}   The code contains a 'logRequestDetails' method that logs:${NC}"
    echo "      - All HTTP headers (including Authorization, Cookie, X-Api-Key)"
    echo "      - Internal AWS resource names (DynamoDB table, S3 bucket)"
    echo "      - SSM parameter values"
    echo "      - Full S3 presigned URLs with credentials"
    FOUND_CODE=true
else
    echo -e "${GREEN}   ✓ No sensitive logging code found in SearchController.java${NC}"
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

ISSUES_FOUND=0
if [ "$FOUND_HEADERS" = true ] || [ "$FOUND_AUTH" = true ]; then
    echo -e "${RED}❌ HTTP Headers/Auth tokens being logged${NC}"
    ((ISSUES_FOUND++))
fi
if [ "$FOUND_RESOURCES" = true ] || [ "$FOUND_DYNAMO" = true ]; then
    echo -e "${RED}❌ Internal AWS resource names being logged${NC}"
    ((ISSUES_FOUND++))
fi
if [ "$FOUND_S3" = true ]; then
    echo -e "${RED}❌ S3 presigned URLs being logged${NC}"
    ((ISSUES_FOUND++))
fi
if [ "$FOUND_SSM" = true ]; then
    echo -e "${RED}❌ SSM parameter values being logged${NC}"
    ((ISSUES_FOUND++))
fi
if [ "$FOUND_CODE" = true ]; then
    echo -e "${RED}❌ Vulnerable code present in SearchController.java${NC}"
    ((ISSUES_FOUND++))
fi

if [ $ISSUES_FOUND -eq 0 ]; then
    echo -e "${GREEN}✅ No security issues detected${NC}"
    echo ""
    echo -e "${YELLOW}   Note: If you just ran inject.sh, the pipeline may still be deploying.${NC}"
    echo -e "${YELLOW}   Wait for deployment to complete and run this script again.${NC}"
else
    echo ""
    echo -e "${RED}🔴 SECURITY VULNERABILITIES DETECTED: $ISSUES_FOUND issues found${NC}"
    echo ""
    echo -e "${YELLOW}📋 Impact:${NC}"
    echo "   - Attackers could harvest credentials from CloudWatch logs"
    echo "   - Internal infrastructure details exposed"
    echo "   - Compliance violations (PCI-DSS, HIPAA, SOC2)"
    echo ""
    echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
    echo ""
    echo -e "   ${CYAN}\"Check the CloudWatch logs for the PetSearch service.${NC}"
    echo -e "   ${CYAN}I'm concerned there might be sensitive data being logged.${NC}"
    echo -e "   ${CYAN}Can you investigate and identify any security issues?\"${NC}"
fi

echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
