#!/bin/bash
# =============================================================================
# Observe Issue Script - Run after injecting a scenario
# =============================================================================
# This script helps you observe the symptoms of each injected issue
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
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_symptom() {
    echo -e "${RED}🔴 SYMPTOM: $1${NC}"
}

print_check() {
    echo -e "${CYAN}🔍 $1${NC}"
}

print_result() {
    echo -e "${YELLOW}   $1${NC}"
}

# Load configuration if exists
if [ -f "$SCRIPT_DIR/.workshop-config" ]; then
    source "$SCRIPT_DIR/.workshop-config"
fi

# Get stack name
STACK_NAME=${STACK_NAME:-"DevOpsAgent-Pipeline-Workshop"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Observe Issue - Symptom Detection Script               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Menu
echo "Which scenario did you inject?"
echo ""
echo "  1) Build Failure (Spring Boot version)"
echo "  2) Runtime Failure (Missing env var)"
echo "  3) Security Issue (Hardcoded credentials)"
echo "  4) Memory Leak (Unbounded cache)"
echo "  5) Database Bottleneck (N+1 query)"
echo "  6) Race Condition (Thread-unsafe code)"
echo "  7) Check all metrics and logs"
echo ""
read -p "Enter scenario number (1-7): " SCENARIO

case $SCENARIO in
    1)
        print_header "Scenario 1: Build Failure"
        print_symptom "Pipeline fails at Build stage with Gradle/Spring Boot error"
        echo ""
        
        print_check "Checking pipeline status..."
        PIPELINE_NAME=$(aws cloudformation describe-stack-resources \
            --stack-name $STACK_NAME \
            --query "StackResources[?ResourceType=='AWS::CodePipeline::Pipeline'].PhysicalResourceId" \
            --output text --region $AWS_REGION 2>/dev/null || echo "")
        
        if [ -n "$PIPELINE_NAME" ]; then
            PIPELINE_STATE=$(aws codepipeline get-pipeline-state --name $PIPELINE_NAME \
                --query 'stageStates[?stageName==`Build`].latestExecution.status' \
                --output text --region $AWS_REGION 2>/dev/null || echo "Unknown")
            print_result "Pipeline: $PIPELINE_NAME"
            print_result "Build Stage Status: $PIPELINE_STATE"
            
            if [ "$PIPELINE_STATE" == "Failed" ]; then
                echo ""
                print_check "Fetching CodeBuild logs (last 20 lines)..."
                CODEBUILD_PROJECT=$(aws codepipeline get-pipeline --name $PIPELINE_NAME \
                    --query 'pipeline.stages[1].actions[0].configuration.ProjectName' \
                    --output text --region $AWS_REGION 2>/dev/null || echo "")
                
                if [ -n "$CODEBUILD_PROJECT" ]; then
                    echo ""
                    aws logs tail "/aws/codebuild/$CODEBUILD_PROJECT" \
                        --since 30m --format short --region $AWS_REGION 2>/dev/null | tail -20 || echo "Could not fetch logs"
                fi
            fi
        else
            print_result "Could not find pipeline. Check stack name."
        fi
        
        echo ""
        echo -e "${GREEN}✅ Expected: Build fails with 'Spring Boot 3.x requires Java 17+' error${NC}"
        ;;
        
    2)
        print_header "Scenario 2: Runtime Failure"
        print_symptom "Service crashes on startup - Missing EXTERNAL_API_KEY"
        echo ""
        
        print_check "Checking ECS service status..."
        # Try to find ECS cluster and service
        CLUSTERS=$(aws ecs list-clusters --query 'clusterArns[*]' --output text --region $AWS_REGION 2>/dev/null)
        
        for CLUSTER_ARN in $CLUSTERS; do
            CLUSTER_NAME=$(echo $CLUSTER_ARN | awk -F'/' '{print $NF}')
            SERVICES=$(aws ecs list-services --cluster $CLUSTER_NAME \
                --query 'serviceArns[*]' --output text --region $AWS_REGION 2>/dev/null)
            
            for SERVICE_ARN in $SERVICES; do
                if [[ "$SERVICE_ARN" == *"earch"* ]] || [[ "$SERVICE_ARN" == *"Search"* ]]; then
                    SERVICE_NAME=$(echo $SERVICE_ARN | awk -F'/' '{print $NF}')
                    print_result "Found service: $SERVICE_NAME in cluster: $CLUSTER_NAME"
                    
                    RUNNING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
                        --query 'services[0].runningCount' --output text --region $AWS_REGION 2>/dev/null)
                    DESIRED=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
                        --query 'services[0].desiredCount' --output text --region $AWS_REGION 2>/dev/null)
                    
                    print_result "Running: $RUNNING / Desired: $DESIRED"
                fi
            done
        done
        
        echo ""
        print_check "Checking CloudWatch logs for errors..."
        LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
            --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
        
        for LOG_GROUP in $LOG_GROUPS; do
            if [[ "$LOG_GROUP" == *"earch"* ]] || [[ "$LOG_GROUP" == *"Search"* ]] || [[ "$LOG_GROUP" == *"pet"* ]]; then
                print_result "Log group: $LOG_GROUP"
                echo ""
                aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --filter-pattern "EXTERNAL_API_KEY" \
                    --start-time $(($(date +%s) * 1000 - 3600000)) \
                    --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | head -5 || echo "No matching logs"
            fi
        done
        
        echo ""
        echo -e "${GREEN}✅ Expected: Logs show 'Missing required configuration: EXTERNAL_API_KEY'${NC}"
        ;;
        
    3)
        print_header "Scenario 3: Security Issue"
        print_symptom "Hardcoded credentials in source code"
        echo ""
        
        print_check "Checking for credentials in code..."
        CONFIG_FILE="$SCRIPT_DIR/../PetAdoptions/petsearch-java/src/main/resources/application-secrets.properties"
        
        if [ -f "$CONFIG_FILE" ]; then
            print_result "Found secrets file: application-secrets.properties"
            echo ""
            echo -e "${RED}Contents (SENSITIVE):${NC}"
            cat "$CONFIG_FILE" 2>/dev/null | head -10
        else
            print_result "Secrets file not found (scenario may not be injected)"
        fi
        
        echo ""
        print_check "Checking git history for secrets..."
        cd "$SCRIPT_DIR/.." 2>/dev/null
        git log --oneline -5 2>/dev/null || echo "Not a git repository"
        
        echo ""
        echo -e "${GREEN}✅ Expected: Credentials visible in application-secrets.properties${NC}"
        ;;
        
    4)
        print_header "Scenario 4: Memory Leak"
        print_symptom "Memory usage steadily increasing over time"
        echo ""
        
        print_check "Checking ECS memory metrics..."
        CLUSTERS=$(aws ecs list-clusters --query 'clusterArns[*]' --output text --region $AWS_REGION 2>/dev/null)
        
        for CLUSTER_ARN in $CLUSTERS; do
            CLUSTER_NAME=$(echo $CLUSTER_ARN | awk -F'/' '{print $NF}')
            SERVICES=$(aws ecs list-services --cluster $CLUSTER_NAME \
                --query 'serviceArns[*]' --output text --region $AWS_REGION 2>/dev/null)
            
            for SERVICE_ARN in $SERVICES; do
                if [[ "$SERVICE_ARN" == *"earch"* ]] || [[ "$SERVICE_ARN" == *"Search"* ]]; then
                    SERVICE_NAME=$(echo $SERVICE_ARN | awk -F'/' '{print $NF}')
                    print_result "Service: $SERVICE_NAME"
                    
                    echo ""
                    print_check "Memory utilization (last 30 minutes):"
                    aws cloudwatch get-metric-statistics \
                        --namespace AWS/ECS \
                        --metric-name MemoryUtilization \
                        --dimensions Name=ClusterName,Value=$CLUSTER_NAME Name=ServiceName,Value=$SERVICE_NAME \
                        --start-time $(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ') \
                        --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
                        --period 300 \
                        --statistics Average \
                        --query 'Datapoints[*].[Timestamp,Average]' \
                        --output table --region $AWS_REGION 2>/dev/null || echo "Could not fetch metrics"
                fi
            done
        done
        
        echo ""
        print_check "Checking logs for cache size growth..."
        LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
            --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
        
        for LOG_GROUP in $LOG_GROUPS; do
            if [[ "$LOG_GROUP" == *"earch"* ]] || [[ "$LOG_GROUP" == *"Search"* ]]; then
                aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --filter-pattern "cache size" \
                    --start-time $(($(date +%s) * 1000 - 1800000)) \
                    --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | tail -5 || echo ""
            fi
        done
        
        echo ""
        echo -e "${GREEN}✅ Expected: Memory utilization climbing, logs show 'cache size' increasing${NC}"
        echo -e "${YELLOW}⚠️  Note: Memory leak takes time to manifest. Generate traffic and wait.${NC}"
        ;;
        
    5)
        print_header "Scenario 5: Database Bottleneck (N+1 Query)"
        print_symptom "Response times 5+ seconds, DynamoDB throttling"
        echo ""
        
        print_check "Generating test traffic (10 concurrent requests)..."
        # Find ALB URL
        ALB_URL=$(aws cloudformation describe-stacks --stack-name Services \
            --query "Stacks[0].Outputs[?OutputKey=='PetSearchServiceURL'].OutputValue" \
            --output text --region $AWS_REGION 2>/dev/null || echo "")
        
        if [ -z "$ALB_URL" ] || [ "$ALB_URL" == "None" ]; then
            # Try to find ALB directly
            ALB_DNS=$(aws elbv2 describe-load-balancers \
                --query "LoadBalancers[?contains(LoadBalancerName, 'pet') || contains(LoadBalancerName, 'Pet')].DNSName" \
                --output text --region $AWS_REGION 2>/dev/null | head -1)
            if [ -n "$ALB_DNS" ]; then
                ALB_URL="http://$ALB_DNS"
            fi
        fi
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            echo ""
            print_check "Measuring response times..."
            
            TOTAL_TIME=0
            SUCCESS=0
            FAILED=0
            
            for i in {1..10}; do
                START=$(date +%s%N)
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$ALB_URL/api/search?pettype=puppy" 2>/dev/null || echo "000")
                END=$(date +%s%N)
                DURATION=$(( (END - START) / 1000000 ))
                
                if [ "$RESPONSE" == "200" ]; then
                    SUCCESS=$((SUCCESS + 1))
                    TOTAL_TIME=$((TOTAL_TIME + DURATION))
                    print_result "Request $i: ${DURATION}ms (HTTP $RESPONSE)"
                else
                    FAILED=$((FAILED + 1))
                    print_result "Request $i: FAILED (HTTP $RESPONSE)"
                fi
            done
            
            if [ $SUCCESS -gt 0 ]; then
                AVG=$((TOTAL_TIME / SUCCESS))
                echo ""
                print_result "Average response time: ${AVG}ms"
                print_result "Success: $SUCCESS / Failed: $FAILED"
            fi
        else
            print_result "Could not find service URL. Check CloudFormation outputs."
        fi
        
        echo ""
        print_check "Checking DynamoDB throttling..."
        TABLES=$(aws dynamodb list-tables --query 'TableNames[*]' --output text --region $AWS_REGION 2>/dev/null)
        for TABLE in $TABLES; do
            if [[ "$TABLE" == *"pet"* ]] || [[ "$TABLE" == *"Pet"* ]]; then
                print_result "Table: $TABLE"
                aws cloudwatch get-metric-statistics \
                    --namespace AWS/DynamoDB \
                    --metric-name ThrottledRequests \
                    --dimensions Name=TableName,Value=$TABLE \
                    --start-time $(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ') \
                    --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
                    --period 300 \
                    --statistics Sum \
                    --query 'Datapoints[*].[Timestamp,Sum]' \
                    --output table --region $AWS_REGION 2>/dev/null || echo "Could not fetch metrics"
            fi
        done
        
        echo ""
        echo -e "${GREEN}✅ Expected: Response times > 5 seconds, possible throttling${NC}"
        ;;
        
    6)
        print_header "Scenario 6: Race Condition"
        print_symptom "Random 500 errors (5-15% of requests)"
        echo ""
        
        # Find ALB URL
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
        
        if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
            print_result "Service URL: $ALB_URL"
            echo ""
            print_check "Sending 50 concurrent requests to trigger race condition..."
            
            SUCCESS=0
            FAILED=0
            
            # Send concurrent requests
            for i in {1..50}; do
                curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "$ALB_URL/api/search?pettype=puppy&petcolor=brown" 2>/dev/null &
            done
            
            # Collect results
            RESULTS=$(wait; echo "done")
            
            # Count results from a second batch (more controlled)
            echo ""
            print_check "Measuring error rate (20 sequential requests)..."
            for i in {1..20}; do
                RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL/api/search?pettype=kitten" 2>/dev/null || echo "000")
                if [ "$RESPONSE" == "200" ]; then
                    SUCCESS=$((SUCCESS + 1))
                else
                    FAILED=$((FAILED + 1))
                    print_result "Request $i: HTTP $RESPONSE (FAILED)"
                fi
            done
            
            TOTAL=$((SUCCESS + FAILED))
            if [ $TOTAL -gt 0 ]; then
                ERROR_RATE=$((FAILED * 100 / TOTAL))
                echo ""
                print_result "Success: $SUCCESS / Failed: $FAILED"
                print_result "Error rate: ${ERROR_RATE}%"
            fi
        else
            print_result "Could not find service URL"
        fi
        
        echo ""
        print_check "Checking logs for ConcurrentModificationException..."
        LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
            --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
        
        for LOG_GROUP in $LOG_GROUPS; do
            if [[ "$LOG_GROUP" == *"earch"* ]] || [[ "$LOG_GROUP" == *"Search"* ]]; then
                echo ""
                aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --filter-pattern "ConcurrentModificationException" \
                    --start-time $(($(date +%s) * 1000 - 1800000)) \
                    --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | head -3 || echo "No ConcurrentModificationException found"
                    
                aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                    --filter-pattern "NullPointerException" \
                    --start-time $(($(date +%s) * 1000 - 1800000)) \
                    --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | head -3 || echo "No NullPointerException found"
            fi
        done
        
        echo ""
        echo -e "${GREEN}✅ Expected: 5-15% error rate, ConcurrentModificationException in logs${NC}"
        ;;
        
    7)
        print_header "Checking All Metrics and Logs"
        
        print_check "Pipeline Status..."
        PIPELINE_NAME=$(aws cloudformation describe-stack-resources \
            --stack-name $STACK_NAME \
            --query "StackResources[?ResourceType=='AWS::CodePipeline::Pipeline'].PhysicalResourceId" \
            --output text --region $AWS_REGION 2>/dev/null || echo "Not found")
        print_result "Pipeline: $PIPELINE_NAME"
        
        print_check "ECS Services..."
        aws ecs list-clusters --query 'clusterArns[*]' --output table --region $AWS_REGION 2>/dev/null
        
        print_check "Recent CloudWatch Errors..."
        LOG_GROUPS=$(aws logs describe-log-groups --log-group-name-prefix "/ecs" \
            --query 'logGroups[*].logGroupName' --output text --region $AWS_REGION 2>/dev/null)
        
        for LOG_GROUP in $LOG_GROUPS; do
            echo "Log group: $LOG_GROUP"
            aws logs filter-log-events --log-group-name "$LOG_GROUP" \
                --filter-pattern "ERROR" \
                --start-time $(($(date +%s) * 1000 - 1800000)) \
                --max-events 5 \
                --query 'events[*].message' --output text --region $AWS_REGION 2>/dev/null | head -5
        done
        ;;
        
    *)
        echo "Invalid option"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Observation complete. Use DevOps Agent to investigate further!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
