#!/bin/bash
# =============================================================================
# Scenario 2: Runtime Failure - Complete End-to-End Script
# =============================================================================
# This script does everything in one shot:
# 1. Injects the issue (missing env var)
# 2. Commits and pushes to GitHub
# 3. Triggers CodePipeline build
# 4. Waits for build to complete
# 5. Deploys to ECS
# 6. Waits for deployment
# 7. Shows the error in CloudWatch logs
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

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
PIPELINE_NAME="${PIPELINE_NAME:-DevOpsAgent-Pipeline-Workshop-Pipeline-0NHaleIMiheT}"

# Load config if exists
if [ -f "$WORKSHOP_DIR/.workshop-config" ]; then
    source "$WORKSHOP_DIR/.workshop-config"
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Scenario 2: Runtime Failure - Missing Environment Variable      ║${NC}"
echo -e "${BLUE}║  Complete End-to-End Execution                                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📋 Story: A developer adds a feature requiring an env var but forgets${NC}"
echo -e "${YELLOW}          to add it to the ECS task definition${NC}"
echo ""

# =============================================================================
# STEP 1: Inject the issue
# =============================================================================
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 1: Injecting the issue${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

# Backup original file
cp "$CONTROLLER" "$CONTROLLER.backup"

# Create the modified controller with the injected code
cat > "$CONTROLLER" << 'JAVAEOF'
package ca.petsearch.controllers;

import ca.petsearch.MetricEmitter;
import ca.petsearch.RandomNumberGenerator;
import com.amazonaws.HttpMethod;
import com.amazonaws.services.dynamodbv2.AmazonDynamoDB;
import com.amazonaws.services.dynamodbv2.model.AttributeValue;
import com.amazonaws.services.dynamodbv2.model.ComparisonOperator;
import com.amazonaws.services.dynamodbv2.model.Condition;
import com.amazonaws.services.dynamodbv2.model.ScanRequest;
import com.amazonaws.services.s3.AmazonS3;
import com.amazonaws.services.s3.model.GeneratePresignedUrlRequest;
import com.amazonaws.services.simplesystemsmanagement.AWSSimpleSystemsManagement;
import com.amazonaws.services.simplesystemsmanagement.model.GetParameterRequest;
import com.amazonaws.services.simplesystemsmanagement.model.GetParameterResult;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@RestController
public class SearchController {
    public static final String BUCKET_NAME = "/petstore/s3bucketname";
    public static final String DYNAMODB_TABLENAME = "/petstore/dynamodbtablename";
    private final RandomNumberGenerator randomGenerator;

    private Logger logger = LoggerFactory.getLogger(SearchController.class);

    private final AmazonS3 s3Client;
    private final AmazonDynamoDB ddbClient;
    private final AWSSimpleSystemsManagement ssmClient;
    private final MetricEmitter metricEmitter;
    private final Tracer tracer;
    private Map<String, String> paramCache = new HashMap<>();

    public SearchController(AmazonS3 s3Client, AmazonDynamoDB ddbClient, AWSSimpleSystemsManagement ssmClient, MetricEmitter metricEmitter, Tracer tracer, RandomNumberGenerator randomGenerator) {
        this.s3Client = s3Client;
        this.ddbClient = ddbClient;
        this.ssmClient = ssmClient;
        this.metricEmitter = metricEmitter;
        this.tracer = tracer;
        this.randomGenerator = randomGenerator;
    }

    private String getKey(String petType, String petId) {

        String folderName;

        switch (petType) {
            case "bunny":
                folderName = "bunnies";
                break;
            case "puppy":
                folderName = "puppies";
                break;
            default:
                folderName = "kitten";
                break;
        }

        return String.format("%s/%s.jpg", folderName, petId);

    }

    private String getPetUrl(String petType, String image) {
        Span span = tracer.spanBuilder("Get Pet URL").startSpan();

        try(Scope scope = span.makeCurrent()) {

            String s3BucketName = getSSMParameter(BUCKET_NAME);

            String key = getKey(petType, image);
            
            Double randomnumber = Math.random()*9999;

            if (randomnumber < 100) {
                logger.debug("Forced exception to show S3 bucket creation error. The bucket never really gets created due to lack of permissions");
                logger.info("Trying to create a S3 Bucket");
                logger.info(randomnumber + " is the random number");
                s3Client.createBucket(s3BucketName);
            }

            logger.info("Generating presigned url");
            GeneratePresignedUrlRequest generatePresignedUrlRequest =
                    new GeneratePresignedUrlRequest(s3BucketName, key)
                            .withMethod(HttpMethod.GET)
                            .withExpiration(new Date(System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(5)));

            return s3Client.generatePresignedUrl(generatePresignedUrlRequest).toString();

        } catch (Exception e) {
            logger.error("Error while accessing S3 bucket", e);
            span.recordException(e);
            throw (e);
        } finally {
            span.end();
        }
    }

    @WithSpan("Get parameter from Systems Manager or cache")
    private String getSSMParameter(String paramName) {
        if (!paramCache.containsKey(paramName)) {
            GetParameterRequest parameterRequest = new GetParameterRequest().withName(paramName).withWithDecryption(false);

            GetParameterResult parameterResult = ssmClient.getParameter(parameterRequest);
            paramCache.put(paramName, parameterResult.getParameter().getValue());
        }
        return paramCache.get(paramName);
    }

    private Pet mapToPet(Map<String, AttributeValue> item) {
        String petId = item.get("petid").getS();
        String availability = item.get("availability").getS();
        String cutenessRate = item.get("cuteness_rate").getS();
        String petColor = item.get("petcolor").getS();
        String petType = item.get("pettype").getS();
        String price = item.get("price").getS();
        String petUrl = getPetUrl(petType, item.get("image").getS());

        Pet currentPet = new Pet(petId, availability, cutenessRate, petColor, petType, price, petUrl);
        return currentPet;
    }


    @GetMapping("/api/search")
    public List<Pet> search(
            @RequestParam(name = "pettype", defaultValue = "", required = false) String petType,
            @RequestParam(name = "petcolor", defaultValue = "", required = false) String petColor,
            @RequestParam(name = "petid", defaultValue = "", required = false) String petId
    ) throws InterruptedException {
        
        String apiKey = System.getenv("EXTERNAL_API_KEY");
        if (apiKey == null || apiKey.isEmpty()) {
            logger.error("EXTERNAL_API_KEY environment variable is not set");
            throw new RuntimeException("Missing required configuration: EXTERNAL_API_KEY");
        }
        logger.info("External API configured, proceeding with search");
        
        Span span = tracer.spanBuilder("Scanning DynamoDB Table").startSpan();

        // This line is intentional. Delays searches
        if (petType != null && !petType.trim().isEmpty() && petType.equals("bunny")) {
            logger.debug("Delaying the response on purpose, to show on traces as an issue");
            TimeUnit.MILLISECONDS.sleep(3000);
        }
        try(Scope scope = span.makeCurrent()) {

            List<Pet> result = ddbClient.scan(
                    buildScanRequest(petType, petColor, petId))
                    .getItems().stream().map(this::mapToPet)
                    .collect(Collectors.toList());
            metricEmitter.emitPetsReturnedMetric(result.size());
            return result;

        } catch (Exception e) {
            span.recordException(e);
            logger.error("Error while searching, building the resulting body", e);
            throw e;
        } finally {
            span.end();
        }

    }

    private ScanRequest buildScanRequest(String petType, String petColor, String petId) {
        return Map.of("pettype", petType,
                "petcolor", petColor,
                "petid", petId).entrySet().stream()
                .filter(e -> !isEmptyParameter(e))
                .map(this::entryToCondition)
                .reduce(emptyScanRequest(), this::addScanFilter, this::joinScanResult);
    }

    private ScanRequest addScanFilter(ScanRequest scanResult, Map.Entry<String, Condition> element) {
        return scanResult.addScanFilterEntry(element.getKey(), element.getValue());
    }

    private ScanRequest emptyScanRequest() {
        return new ScanRequest().withTableName(getSSMParameter(DYNAMODB_TABLENAME));
    }

    private ScanRequest joinScanResult(ScanRequest scanRequest1, ScanRequest scanRequest2) {
        Map<String, Condition> merged = new HashMap<>();
        merged.putAll(scanRequest1.getScanFilter() != null ? scanRequest1.getScanFilter() : Collections.emptyMap());
        merged.putAll(scanRequest2.getScanFilter() != null ? scanRequest2.getScanFilter() : Collections.emptyMap());

        return scanRequest1.withScanFilter(merged);
    }

    private Map.Entry<String, Condition> entryToCondition(Map.Entry<String, String> e) {
        Span.current().setAttribute(e.getKey(), e.getValue());
        return Map.entry(e.getKey(), new Condition()
                .withComparisonOperator(ComparisonOperator.EQ)
                .withAttributeValueList(new AttributeValue().withS(e.getValue())));
    }

    private boolean isEmptyParameter(Map.Entry<String, String> e) {
        return e.getValue() == null || e.getValue().isEmpty();
    }

}
JAVAEOF

echo -e "${GREEN}   ✓ Code injected: Added EXTERNAL_API_KEY check${NC}"

# =============================================================================
# STEP 2: Commit and push to CodeCommit
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 2: Committing and pushing to CodeCommit${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

cd "$REPO_ROOT"

# Configure CodeCommit remote if not already set
CODECOMMIT_URL=$(aws cloudformation describe-stacks \
    --query "Stacks[?contains(StackName, 'Pipeline') || contains(StackName, 'Workshop')].Outputs[?OutputKey=='CodeCommitRepoCloneUrlHttp'].OutputValue" \
    --output text --region $AWS_REGION 2>/dev/null | head -1)

if [ -n "$CODECOMMIT_URL" ]; then
    git remote set-url origin "$CODECOMMIT_URL" 2>/dev/null || git remote add origin "$CODECOMMIT_URL"
fi

git add PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java
git commit -m "feat: integrate external API for enhanced pet search" 2>/dev/null || echo "   (No changes to commit)"
git push origin main

echo -e "${GREEN}   ✓ Changes pushed to CodeCommit${NC}"

# =============================================================================
# STEP 3: Trigger CodePipeline build
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 3: Triggering CodePipeline build${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

EXECUTION_ID=$(aws codepipeline start-pipeline-execution \
    --name $PIPELINE_NAME \
    --region $AWS_REGION \
    --query 'pipelineExecutionId' \
    --output text 2>/dev/null)

echo -e "${GREEN}   ✓ Pipeline execution started: $EXECUTION_ID${NC}"

# =============================================================================
# STEP 4: Wait for build to complete
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 4: Waiting for build to complete (3-5 minutes)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

BUILD_STATUS="InProgress"
COUNTER=0
MAX_WAIT=600

while [ "$BUILD_STATUS" == "InProgress" ] && [ $COUNTER -lt $MAX_WAIT ]; do
    sleep 10
    COUNTER=$((COUNTER + 10))
    
    BUILD_STATUS=$(aws codepipeline get-pipeline-state \
        --name $PIPELINE_NAME \
        --region $AWS_REGION \
        --query 'stageStates[?stageName==`Build`].latestExecution.status' \
        --output text 2>/dev/null)
    
    echo -ne "\r   Build status: $BUILD_STATUS (${COUNTER}s elapsed)          "
done

echo ""

if [ "$BUILD_STATUS" != "Succeeded" ]; then
    echo -e "${RED}   ✗ Build failed or timed out. Status: $BUILD_STATUS${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Build completed successfully!${NC}"

# =============================================================================
# STEP 5: Find ECS cluster and service
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 5: Finding ECS cluster and service${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CLUSTER_NAME=""
SERVICE_NAME=""

CLUSTERS=$(aws ecs list-clusters --query 'clusterArns[*]' --output text --region $AWS_REGION 2>/dev/null)

for CLUSTER_ARN in $CLUSTERS; do
    CLUSTER=$(echo $CLUSTER_ARN | awk -F'/' '{print $NF}')
    SERVICES=$(aws ecs list-services --cluster $CLUSTER --query 'serviceArns[*]' --output text --region $AWS_REGION 2>/dev/null)
    
    for SERVICE_ARN in $SERVICES; do
        if [[ "$SERVICE_ARN" == *"earch"* ]] || [[ "$SERVICE_ARN" == *"Search"* ]]; then
            CLUSTER_NAME=$CLUSTER
            SERVICE_NAME=$(echo $SERVICE_ARN | awk -F'/' '{print $NF}')
            break 2
        fi
    done
done

echo -e "${GREEN}   ✓ Cluster: $CLUSTER_NAME${NC}"
echo -e "${GREEN}   ✓ Service: $SERVICE_NAME${NC}"

# =============================================================================
# STEP 6: Get latest image and update task definition
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 6: Creating new task definition with latest image${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

TASK_DEF_ARN=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
    --query 'services[0].taskDefinition' --output text --region $AWS_REGION)

CONTAINER_IMAGE=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN \
    --query 'taskDefinition.containerDefinitions[?name!=`aws-otel-collector`].image' \
    --output text --region $AWS_REGION | head -1)

ECR_REPO=$(echo $CONTAINER_IMAGE | awk -F':' '{print $1}')
ECR_REPO_NAME=$(echo $ECR_REPO | awk -F'/' '{print $NF}')

LATEST_IMAGE_TAG=$(aws ecr describe-images \
    --repository-name $ECR_REPO_NAME \
    --region $AWS_REGION \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
    --output text 2>/dev/null)

if [ -z "$LATEST_IMAGE_TAG" ] || [ "$LATEST_IMAGE_TAG" == "None" ]; then
    LATEST_IMAGE_TAG="latest"
fi

FULL_IMAGE_URI="$ECR_REPO:$LATEST_IMAGE_TAG"
echo -e "${GREEN}   ✓ Latest image: $FULL_IMAGE_URI${NC}"

# Create new task definition
TEMP_FILE="/tmp/task-def-$$.json"
UPDATED_FILE="/tmp/task-def-updated-$$.json"

aws ecs describe-task-definition --task-definition $TASK_DEF_ARN \
    --query 'taskDefinition' --region $AWS_REGION > $TEMP_FILE

cat $TEMP_FILE | jq --arg IMAGE "$FULL_IMAGE_URI" '
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
    .containerDefinitions = [.containerDefinitions[] | if .name != "aws-otel-collector" then .image = $IMAGE else . end]
' > $UPDATED_FILE

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file://$UPDATED_FILE \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text --region $AWS_REGION)

rm -f $TEMP_FILE $UPDATED_FILE

echo -e "${GREEN}   ✓ New Task Definition: $(echo $NEW_TASK_DEF_ARN | awk -F'/' '{print $NF}')${NC}"

# =============================================================================
# STEP 7: Deploy to ECS
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 7: Deploying to ECS${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --task-definition $NEW_TASK_DEF_ARN \
    --force-new-deployment \
    --region $AWS_REGION > /dev/null

echo -e "${GREEN}   ✓ ECS service update initiated${NC}"

# =============================================================================
# STEP 8: Wait for deployment
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 8: Waiting for ECS deployment (2-5 minutes)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

COUNTER=0
MAX_WAIT=300

while [ $COUNTER -lt $MAX_WAIT ]; do
    sleep 10
    COUNTER=$((COUNTER + 10))
    
    RUNNING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].runningCount' --output text --region $AWS_REGION)
    DESIRED=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].desiredCount' --output text --region $AWS_REGION)
    PENDING=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'services[0].pendingCount' --output text --region $AWS_REGION)
    
    echo -ne "\r   Running: $RUNNING/$DESIRED, Pending: $PENDING (${COUNTER}s elapsed)    "
    
    DEPLOYMENTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
        --query 'length(services[0].deployments)' --output text --region $AWS_REGION)
    
    if [ "$DEPLOYMENTS" == "1" ] && [ "$RUNNING" == "$DESIRED" ]; then
        break
    fi
done

echo ""
echo -e "${GREEN}   ✓ Deployment complete${NC}"

# =============================================================================
# STEP 9: Show the error in CloudWatch logs
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  STEP 9: Checking CloudWatch logs for errors${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "${YELLOW}   Waiting 30 seconds for logs to appear...${NC}"
sleep 30

echo ""
echo -e "${RED}   🔴 Expected Error in Logs:${NC}"
echo ""

aws logs filter-log-events --log-group-name "/ecs/PetSearch" \
    --filter-pattern "EXTERNAL_API_KEY" \
    --start-time $(($(date +%s) * 1000 - 300000)) \
    --region $AWS_REGION \
    --query 'events[*].message' --output text 2>/dev/null | head -5

echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    SCENARIO 2 COMPLETE                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✅ Issue Injected:${NC} Missing EXTERNAL_API_KEY environment variable"
echo -e "${GREEN}✅ Code Pushed:${NC} Commit pushed to GitHub"
echo -e "${GREEN}✅ Build:${NC} Succeeded (code compiles fine)"
echo -e "${GREEN}✅ Deployed:${NC} New container running in ECS"
echo -e "${RED}❌ Runtime:${NC} Service returns 500 errors on /api/search"
echo ""
echo -e "${YELLOW}📋 What to do now:${NC}"
echo ""
echo "   1. Use DevOps Agent to investigate:"
echo -e "      ${CYAN}\"The PetSearch service is returning 500 errors after a recent${NC}"
echo -e "      ${CYAN}deployment. Investigate if the code changes are related.\"${NC}"
echo ""
echo "   2. Check CloudWatch logs manually:"
echo "      aws logs tail /ecs/PetSearch --since 5m --region $AWS_REGION"
echo ""
echo "   3. After investigation, run the fix:"
echo "      ./fix.sh"
echo ""
