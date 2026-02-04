#!/bin/bash
# =============================================================================
# Scenario 1: Verify Fix - Build Failure (Spring Boot Version)
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
STACK_NAME="${STACK_NAME:-DevOpsAgent-Pipeline-Workshop}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 1: Verify Fix - Build Failure                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0
FAILED=0

# =============================================================================
# Check 1: Verify build.gradle has correct Spring Boot version
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 1: Spring Boot Version in build.gradle${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

BUILD_GRADLE="$REPO_ROOT/PetAdoptions/petsearch-java/build.gradle"
if [ -f "$BUILD_GRADLE" ]; then
    VERSION=$(grep "org.springframework.boot" "$BUILD_GRADLE" | grep -o "'[0-9.]*'" | tr -d "'" | head -1)
    echo -e "   Spring Boot version: ${CYAN}$VERSION${NC}"
    
    if [[ "$VERSION" == "2.7"* ]]; then
        echo -e "${GREEN}   ✓ Correct version (2.7.x) - compatible with Java 11${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}   ✗ Version $VERSION may not be compatible with Java 11${NC}"
        FAILED=$((FAILED + 1))
    fi
else
    echo -e "${RED}   ✗ build.gradle not found${NC}"
    FAILED=$((FAILED + 1))
fi

# =============================================================================
# Check 2: Pipeline Build Status
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Check 2: Pipeline Build Status${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

PIPELINE_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name $STACK_NAME \
    --query "StackResources[?ResourceType=='AWS::CodePipeline::Pipeline'].PhysicalResourceId" \
    --output text --region $AWS_REGION 2>/dev/null || echo "")

if [ -n "$PIPELINE_NAME" ] && [ "$PIPELINE_NAME" != "None" ]; then
    echo -e "   Pipeline: ${CYAN}$PIPELINE_NAME${NC}"
    
    BUILD_STATUS=$(aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
        --query 'stageStates[?stageName==`Build`].latestExecution.status' \
        --output text --region $AWS_REGION 2>/dev/null || echo "Unknown")
    
    echo -e "   Build Stage Status: ${CYAN}$BUILD_STATUS${NC}"
    
    if [ "$BUILD_STATUS" == "Succeeded" ]; then
        echo -e "${GREEN}   ✓ Build succeeded${NC}"
        PASSED=$((PASSED + 1))
    elif [ "$BUILD_STATUS" == "InProgress" ]; then
        echo -e "${YELLOW}   ⏳ Build in progress - wait for completion${NC}"
        echo -e "   Monitor: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view"
    else
        echo -e "${RED}   ✗ Build status: $BUILD_STATUS${NC}"
        FAILED=$((FAILED + 1))
    fi
else
    echo -e "${YELLOW}   ⚠️  Pipeline not found - may need to push fix first${NC}"
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
