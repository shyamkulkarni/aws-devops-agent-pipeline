#!/bin/bash
# =============================================================================
# Verify Fix Script - Run after applying a fix
# =============================================================================
# This script verifies that the fix resolved the issue
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

print_header() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_fail() {
    echo -e "${RED}❌ $1${NC}"
}

print_check() {
    echo -e "${CYAN}🔍 $1${NC}"
}

print_result() {
    echo -e "${YELLOW}   $1${NC}"
}

print_waiting() {
    echo -e "${YELLOW}⏳ $1${NC}"
}

# Load configuration if exists
if [ -f "$SCRIPT_DIR/.workshop-config" ]; then
    source "$SCRIPT_DIR/.workshop-config"
fi

# Get stack name
STACK_NAME=${STACK_NAME:-"DevOpsAgent-Pipeline-Workshop"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Verify Fix - Confirmation Script                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Menu
echo "Which scenario fix did you apply?"
echo ""
echo "  1) Build Failure (Spring Boot version)"
echo "  2) Runtime Failure (Missing env var)"
echo "  3) Security Issue (Hardcoded credentials)"
echo "  4) Memory Leak (Unbounded cache)"
echo "  5) Database Bottleneck (N+1 query)"
echo "  6) Race Condition (Thread-unsafe code)"
echo ""
read -p "Enter scenario number (1-6): " SCENARIO

# Helper function to find service URL
find_service_url() {
    ALB_URL=$(aws cloudformation describe-stacks --stack-name Services \
        --query "Stacks[0].Outputs[?OutputKey=='PetSearchServiceURL'].OutputValue" \
        --output text --region $AWS_REGION 2>/dev/null || echo "")
    
    if [ -z "$ALB_URL" ] || [ "$ALB_URL" == "None" ]; then
        ALB_DNS=$(aws elbv2 describe-load-balancers \
            --query "LoadBalancers[?contains(LoadBalancerName, 'pet') || contains(LoadBalancerName, 'Pet')].DNSName" \
            --output text --region $AWS_REGION 2>/dev/null | head -1)
        if [ -n "$ALB_DNS" ]; then
            ALB_URL="http://$ALB_DNS"
        fi
    fi
    echo "$ALB_URL"
}

case $SCENARIO in
    1)
        print_header "Verifying Scenario 1 Fix: Build Failure"
        echo ""
        
        print_check "Checking pipeline status..."
        PIPELINE_NAME=$(aws cloudformation describe-stack-resources \
            --stack-name $STACK_NAME \
            --query "StackResources[?ResourceType=='AWS::CodePipeline::Pipeline'].PhysicalResourceId" \
            --output text --region $AWS_REGION 2>/dev/null || echo "")
        
        if [ -n "$PIPELINE_NAME" ]; then
            print_result "Pipeline: $PIPELINE_NAME"
            
            # Check if pipeline is running
            PIPELINE_STATE=$(aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
                --query 'stageStates[?stageName==`Build`].latestExecution.status' \
                --output text --region $AWS_REGION 2>/dev/null || echo "Unknown")
            
            print_result "Build Stage Status: $PIPELINE_STATE"
            
            if [ "$PIPELINE_STATE" == "InProgress" ]; then
                print_waiting "Pipeline is still running. Please wait for completion."
                echo ""
                echo "Monitor at: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view"
            elif [ "$PIPELINE_STATE" == "Succeeded" ]; then
                print_success "Build succeeded! Fix verified."
            elif [ "$PIPELINE_STATE" == "Failed" ]; then
                print_fail "Build still failing. Check if fix was pushed correctly."
            fi
        fi
        
        echo ""
        print_check "Verifying build.gradle has correct Spring Boot version..."
        BUILD_GRADLE="$SCRIPT_DIR/../PetAdoptions/petsearch-java/build.gradle"
        if [ -f "$BUILD_GRADLE" ]; then
            VERSION=$(grep "org.springframework.boot" "$BUILD_GRADLE" | grep -o "'[0-9.]*'" | tr -d "'")
            print_result "Spring Boot version: $VERSION"
            
            if [[ "$VERSION" == "2.7"* ]]; then
                print_success "Correct version (2.7.x) - compatible with Java 11"
            else
                print_fail "Version $VERSION may not be compatible with Java 11"
            fi
        fi
        ;;
        
    2)
        print_header "Verifying Scenario 2 Fix: Runtime Failure"
        echo ""
        
        print_check "Checking if service is healthy..."
        ALB_URL=$(find_service_url)
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            
            print_check "Testing endpoint..."
            RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
            
            if [ "$RESPONSE" == "200" ]; then
                print_success "Service responding with HTTP 200"
            else
                print_fail "Service returned HTTP $RESPONSE"
                
                print_check "Checking recent logs for errors..."
                LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
                    --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
                
                for LOG_GROUP in $LOG_GROUPS; do
                    if [[ "$LOG_GROUP" == *"earch"* ]] || [[ "$LOG_GROUP" == *"Search"* ]]; then
                        aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                            --filter-pattern "ERROR" \
                            --start-time $(($(date +%s) * 1000 - 600000)) \
                            --max-events 3 \
                            --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | head -3
                    fi
                done
            fi
        else
            print_waiting "Service URL not found. Deployment may still be in progress."
        fi
        
        echo ""
        print_check "Verifying SearchController doesn't require EXTERNAL_API_KEY..."
        CONTROLLER="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
        if [ -f "$CONTROLLER" ]; then
            if grep -q "EXTERNAL_API_KEY" "$CONTROLLER"; then
                print_fail "EXTERNAL_API_KEY check still present in code"
            else
                print_success "EXTERNAL_API_KEY check removed from code"
            fi
        fi
        ;;
        
    3)
        print_header "Verifying Scenario 3 Fix: Security Issue"
        echo ""
        
        print_check "Checking for secrets file..."
        SECRETS_FILE="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/resources/application-secrets.properties"
        
        if [ -f "$SECRETS_FILE" ]; then
            print_fail "Secrets file still exists: application-secrets.properties"
            echo ""
            echo "Contents:"
            cat "$SECRETS_FILE" | head -5
        else
            print_success "Secrets file removed"
        fi
        
        echo ""
        print_check "Scanning code for hardcoded credentials..."
        FOUND_SECRETS=0
        
        # Check for common secret patterns
        if grep -r "aws_access_key_id\|aws_secret_access_key\|password\s*=\s*['\"]" \
            "$SCRIPT_DIR/../PetAdoptions/petsearch-java/src" 2>/dev/null | grep -v ".backup"; then
            print_fail "Potential secrets found in code"
            FOUND_SECRETS=1
        fi
        
        if [ $FOUND_SECRETS -eq 0 ]; then
            print_success "No hardcoded credentials detected"
        fi
        ;;
        
    4)
        print_header "Verifying Scenario 4 Fix: Memory Leak"
        echo ""
        
        print_check "Verifying cache code removed..."
        CONTROLLER="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
        
        if [ -f "$CONTROLLER" ]; then
            if grep -q "searchResultCache\|requestPayloadHistory" "$CONTROLLER"; then
                print_fail "Cache variables still present in code"
            else
                print_success "Unbounded cache code removed"
            fi
        fi
        
        echo ""
        print_check "Testing service health..."
        ALB_URL=$(find_service_url)
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            
            # Send some requests
            SUCCESS=0
            for i in {1..5}; do
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
                if [ "$RESPONSE" == "200" ]; then
                    SUCCESS=$((SUCCESS + 1))
                fi
            done
            
            print_result "Successful requests: $SUCCESS/5"
            
            if [ $SUCCESS -eq 5 ]; then
                print_success "Service responding normally"
            fi
        fi
        
        echo ""
        echo -e "${YELLOW}💡 Note: Memory metrics will stabilize over time after fix deployment${NC}"
        ;;
        
    5)
        print_header "Verifying Scenario 5 Fix: Database Bottleneck"
        echo ""
        
        print_check "Verifying N+1 query code removed..."
        CONTROLLER="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
        
        if [ -f "$CONTROLLER" ]; then
            if grep -q "enrichPetWithAdditionalData" "$CONTROLLER"; then
                print_fail "N+1 query code still present"
            else
                print_success "N+1 query code removed"
            fi
        fi
        
        echo ""
        print_check "Testing response times..."
        ALB_URL=$(find_service_url)
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            
            TOTAL_TIME=0
            SUCCESS=0
            
            for i in {1..5}; do
                START=$(date +%s%N)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
                END=$(date +%s%N)
                DURATION=$(( (END - START) / 1000000 ))
                
                if [ "$RESPONSE" == "200" ]; then
                    SUCCESS=$((SUCCESS + 1))
                    TOTAL_TIME=$((TOTAL_TIME + DURATION))
                    print_result "Request $i: ${DURATION}ms"
                fi
            done
            
            if [ $SUCCESS -gt 0 ]; then
                AVG=$((TOTAL_TIME / SUCCESS))
                echo ""
                print_result "Average response time: ${AVG}ms"
                
                if [ $AVG -lt 2000 ]; then
                    print_success "Response times are healthy (< 2 seconds)"
                else
                    print_fail "Response times still elevated"
                fi
            fi
        fi
        ;;
        
    6)
        print_header "Verifying Scenario 6 Fix: Race Condition"
        echo ""
        
        print_check "Verifying thread-unsafe code removed..."
        CONTROLLER="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
        
        if [ -f "$CONTROLLER" ]; then
            if grep -q "requestCountByPetType\|recentSearches\|trackSearchAnalytics" "$CONTROLLER"; then
                print_fail "Thread-unsafe analytics code still present"
            else
                print_success "Thread-unsafe code removed"
            fi
        fi
        
        echo ""
        print_check "Testing for intermittent failures (30 requests)..."
        ALB_URL=$(find_service_url)
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            
            SUCCESS=0
            FAILED=0
            
            for i in {1..30}; do
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL/api/search?pettype=kitten&petcolor=white" 2>/dev/null || echo "000")
                if [ "$RESPONSE" == "200" ]; then
                    SUCCESS=$((SUCCESS + 1))
                else
                    FAILED=$((FAILED + 1))
                fi
            done
            
            TOTAL=$((SUCCESS + FAILED))
            ERROR_RATE=$((FAILED * 100 / TOTAL))
            
            echo ""
            print_result "Success: $SUCCESS / Failed: $FAILED"
            print_result "Error rate: ${ERROR_RATE}%"
            
            if [ $ERROR_RATE -lt 2 ]; then
                print_success "Error rate is healthy (< 2%)"
            else
                print_fail "Error rate still elevated (${ERROR_RATE}%)"
            fi
        fi
        
        echo ""
        print_check "Checking logs for recent exceptions..."
        LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
            --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
        
        EXCEPTIONS_FOUND=0
        for LOG_GROUP in $LOG_GROUPS; do
            if [[ "$LOG_GROUP" == *"earch"* ]] || [[ "$LOG_GROUP" == *"Search"* ]]; then
                COUNT=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --filter-pattern "ConcurrentModificationException" \
                    --start-time $(($(date +%s) * 1000 - 600000)) \
                    --query 'events | length(@)' --output text --region $AWS_REGION 2>/dev/null || echo "0")
                
                if [ "$COUNT" != "0" ] && [ "$COUNT" != "None" ]; then
                    EXCEPTIONS_FOUND=$((EXCEPTIONS_FOUND + COUNT))
                fi
            fi
        done
        
        if [ $EXCEPTIONS_FOUND -eq 0 ]; then
            print_success "No ConcurrentModificationException in recent logs"
        else
            print_result "Found $EXCEPTIONS_FOUND exceptions in last 10 minutes (may be from before fix)"
        fi
        ;;
        
    *)
        echo "Invalid option"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Verification complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
