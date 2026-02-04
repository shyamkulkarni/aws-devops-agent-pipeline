#!/bin/bash
# =============================================================================
# Scenario 1: Observe Symptoms - Build Failure
# =============================================================================
# This script demonstrates the build failure caused by Spring Boot 3.x
# incompatibility with Java 11
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
WORKSHOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$WORKSHOP_DIR/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Load config if exists
if [ -f "$WORKSHOP_DIR/.workshop-config" ]; then
    source "$WORKSHOP_DIR/.workshop-config"
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 1: Observing Build Failure Symptoms                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Step 1: Check Pipeline Status
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 1: Checking CodePipeline Status${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Find pipeline name
if [ -z "$PIPELINE_NAME" ]; then
    PIPELINE_NAME=$(aws codepipeline list-pipelines --region $AWS_REGION \
        --query 'pipelines[?contains(name, `Workshop`) || contains(name, `DevOps`)].name' \
        --output text 2>/dev/null | head -1)
fi

if [ -z "$PIPELINE_NAME" ]; then
    echo -e "${RED}   ✗ Could not find pipeline${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Pipeline: $PIPELINE_NAME${NC}"
echo ""

# Get pipeline state
PIPELINE_STATE=$(aws codepipeline get-pipeline-state --name $PIPELINE_NAME --region $AWS_REGION 2>/dev/null)

SOURCE_STATUS=$(echo "$PIPELINE_STATE" | jq -r '.stageStates[] | select(.stageName=="Source") | .latestExecution.status')
BUILD_STATUS=$(echo "$PIPELINE_STATE" | jq -r '.stageStates[] | select(.stageName=="Build") | .latestExecution.status')

echo -e "   Source Stage: ${GREEN}$SOURCE_STATUS${NC}"

if [ "$BUILD_STATUS" == "Failed" ]; then
    echo -e "   Build Stage:  ${RED}$BUILD_STATUS${NC}"
else
    echo -e "   Build Stage:  ${YELLOW}$BUILD_STATUS${NC}"
fi

# =============================================================================
# Step 2: Get CodeBuild Logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 2: Checking CodeBuild Logs${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Find CodeBuild project
BUILD_PROJECT=$(aws codebuild list-projects --region $AWS_REGION \
    --query 'projects[?contains(@, `Workshop`) || contains(@, `DevOps`)]' \
    --output text 2>/dev/null | head -1)

if [ -n "$BUILD_PROJECT" ]; then
    echo -e "${GREEN}   ✓ Build Project: $BUILD_PROJECT${NC}"
    echo ""
    
    # Get latest build
    LATEST_BUILD=$(aws codebuild list-builds-for-project --project-name $BUILD_PROJECT \
        --region $AWS_REGION --query 'ids[0]' --output text 2>/dev/null)
    
    if [ -n "$LATEST_BUILD" ] && [ "$LATEST_BUILD" != "None" ]; then
        BUILD_INFO=$(aws codebuild batch-get-builds --ids $LATEST_BUILD --region $AWS_REGION 2>/dev/null)
        BUILD_RESULT=$(echo "$BUILD_INFO" | jq -r '.builds[0].buildStatus')
        
        echo -e "   Latest Build ID: ${CYAN}$(echo $LATEST_BUILD | awk -F':' '{print $NF}')${NC}"
        
        if [ "$BUILD_RESULT" == "FAILED" ]; then
            echo -e "   Build Status:    ${RED}$BUILD_RESULT${NC}"
            echo ""
            echo -e "${YELLOW}   Fetching build logs...${NC}"
            echo ""
            
            # Get CloudWatch log group and stream
            LOG_GROUP=$(echo "$BUILD_INFO" | jq -r '.builds[0].logs.groupName')
            LOG_STREAM=$(echo "$BUILD_INFO" | jq -r '.builds[0].logs.streamName')
            
            if [ -n "$LOG_GROUP" ] && [ "$LOG_GROUP" != "null" ]; then
                echo -e "${RED}   🔴 BUILD ERROR:${NC}"
                echo ""
                
                # Search for the actual error
                aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --log-stream-names "$LOG_STREAM" \
                    --filter-pattern "error" \
                    --region $AWS_REGION \
                    --query 'events[-10:].message' --output text 2>/dev/null | head -20
            fi
        else
            echo -e "   Build Status:    ${GREEN}$BUILD_RESULT${NC}"
        fi
    fi
else
    echo -e "${YELLOW}   Could not find CodeBuild project${NC}"
fi

# =============================================================================
# Step 3: Check Source Code for the Issue
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Step 3: Checking Source Code${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

BUILD_GRADLE="$REPO_ROOT/PetAdoptions/petsearch-java/build.gradle"

if [ -f "$BUILD_GRADLE" ]; then
    SPRING_VERSION=$(grep "org.springframework.boot" "$BUILD_GRADLE" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    
    echo ""
    echo -e "   Spring Boot Version: ${CYAN}$SPRING_VERSION${NC}"
    
    if [[ "$SPRING_VERSION" == 3.* ]]; then
        echo -e "${RED}   🔴 ISSUE DETECTED: Spring Boot 3.x requires Java 17+${NC}"
        echo ""
        echo -e "   The project is configured to use Java 11, but Spring Boot 3.x"
        echo -e "   requires Java 17 or higher. This causes the build to fail."
        ISSUE_FOUND=true
    else
        echo -e "${GREEN}   ✓ Spring Boot version is compatible with Java 11${NC}"
        ISSUE_FOUND=false
    fi
else
    echo -e "${YELLOW}   Could not find build.gradle${NC}"
    ISSUE_FOUND=false
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                         SUMMARY                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$BUILD_STATUS" == "Failed" ] || [ "$ISSUE_FOUND" = true ]; then
    echo -e "${RED}❌ Build:${NC} Failed"
    echo -e "${YELLOW}⚠️  Deploy:${NC} Not attempted (build failed)"
    echo -e "${YELLOW}⚠️  Runtime:${NC} Not applicable"
    echo ""
    echo -e "${YELLOW}📋 Root Cause:${NC}"
    echo "   Spring Boot was upgraded from 2.7.3 to 3.2.0"
    echo "   Spring Boot 3.x requires Java 17+, but project uses Java 11"
    echo ""
    echo -e "${YELLOW}📋 DevOps Agent Investigation Prompt:${NC}"
    echo ""
    echo -e "   ${CYAN}\"The PetSearch service deployment failed. Check the recent code${NC}"
    echo -e "   ${CYAN}changes in the CodeCommit repository and identify what caused${NC}"
    echo -e "   ${CYAN}the build failure.\"${NC}"
else
    echo -e "${GREEN}✅ Build:${NC} Succeeded or In Progress"
    echo ""
    echo -e "${YELLOW}   Note: If you just ran inject.sh, wait for the build to fail.${NC}"
fi

echo ""
echo -e "${YELLOW}📋 To fix this issue:${NC}"
echo "   ./fix.sh"
echo ""
