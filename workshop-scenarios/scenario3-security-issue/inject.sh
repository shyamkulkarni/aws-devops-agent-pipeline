#!/bin/bash
# Scenario 3: Security Issue - Sensitive Data Logging
# This script injects code that logs sensitive request data to CloudWatch
#
# DevOps Agent Demo:
# - Agent checks CloudWatch logs and sees sensitive data being logged
# - Agent scans codebase to find the source of the logging
# - Agent identifies the security vulnerability and recommends fix

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 3: Security Issue - Sensitive Data Logging             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Story: A developer adds verbose debug logging to troubleshoot"
echo "          an issue, but accidentally logs sensitive request data"
echo "          including Authorization headers and internal AWS resources"
echo ""

# Backup original file
cp "$CONTROLLER" "$CONTROLLER.backup"

# Create the modified SearchController with sensitive logging
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
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import javax.servlet.http.HttpServletRequest;
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

    // ============================================================================
    // Debug logging for troubleshooting
    // ============================================================================
    private void logRequestDetails(HttpServletRequest request, String petType, String petColor, String petId) {
        logger.info("=== DEBUG: Incoming Request Details ===");
        logger.info("Request URI: {}", request.getRequestURI());
        logger.info("Remote Address: {}", request.getRemoteAddr());
        logger.info("Query Parameters: pettype={}, petcolor={}, petid={}", petType, petColor, petId);
        
        logger.info("=== REQUEST HEADERS (DEBUG) ===");
        Enumeration<String> headerNames = request.getHeaderNames();
        while (headerNames.hasMoreElements()) {
            String headerName = headerNames.nextElement();
            String headerValue = request.getHeader(headerName);
            logger.info("Header [{}]: {}", headerName, headerValue);
        }
        
        String tableName = getSSMParameter(DYNAMODB_TABLENAME);
        String bucketName = getSSMParameter(BUCKET_NAME);
        logger.info("=== INTERNAL RESOURCES (DEBUG) ===");
        logger.info("DynamoDB Table: {}", tableName);
        logger.info("S3 Bucket: {}", bucketName);
        logger.info("AWS Region: {}", System.getenv("AWS_REGION"));
        logger.info("Task ARN: {}", System.getenv("ECS_CONTAINER_METADATA_URI"));
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
            
            logger.info("DEBUG: Generating presigned URL for bucket={}, key={}", s3BucketName, key);
            
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

            String presignedUrl = s3Client.generatePresignedUrl(generatePresignedUrlRequest).toString();
            
            logger.info("DEBUG: Generated presigned URL: {}", presignedUrl);
            
            return presignedUrl;

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
            
            logger.info("DEBUG: Retrieved SSM parameter {}={}", paramName, parameterResult.getParameter().getValue());
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
            HttpServletRequest request,
            @RequestParam(name = "pettype", defaultValue = "", required = false) String petType,
            @RequestParam(name = "petcolor", defaultValue = "", required = false) String petColor,
            @RequestParam(name = "petid", defaultValue = "", required = false) String petId
    ) throws InterruptedException {
        Span span = tracer.spanBuilder("Scanning DynamoDB Table").startSpan();

        logRequestDetails(request, petType, petColor, petId);

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
            
            logger.info("DEBUG: Returning {} pets: {}", result.size(), result);
            
            return result;

        } catch (Exception e) {
            span.recordException(e);
            logger.error("Error while searching - Full details: query={}, params=[pettype={}, petcolor={}, petid={}]", 
                request.getQueryString(), petType, petColor, petId, e);
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

echo "✅ Code injection complete!"
echo ""
echo "📁 Modified: SearchController.java"
echo ""
echo "🔴 Security vulnerabilities injected:"
echo "   1. Logs ALL HTTP headers (including Authorization, Cookie, X-Api-Key)"
echo "   2. Logs internal AWS resource names (DynamoDB table, S3 bucket)"
echo "   3. Logs SSM parameter values"
echo "   4. Logs full S3 presigned URLs with credentials"
echo "   5. Logs full response data"

# =============================================================================
# Commit and push to CodeCommit
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 Committing and pushing to CodeCommit..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$REPO_ROOT"

# Configure CodeCommit remote if not already set
AWS_REGION="${AWS_REGION:-us-east-1}"
CODECOMMIT_URL=$(aws cloudformation describe-stacks \
    --query "Stacks[?contains(StackName, 'Pipeline') || contains(StackName, 'Workshop')].Outputs[?OutputKey=='CodeCommitRepoCloneUrlHttp'].OutputValue" \
    --output text --region $AWS_REGION 2>/dev/null | head -1)

if [ -n "$CODECOMMIT_URL" ]; then
    git remote set-url origin "$CODECOMMIT_URL" 2>/dev/null || git remote add origin "$CODECOMMIT_URL"
fi

git add -A

if git diff --cached --quiet; then
    echo "   ℹ️  No changes to commit"
else
    git commit -m "feat: add debug logging for troubleshooting"
    echo "   ✅ Changes committed"
fi

git push origin main
echo "   ✅ Pushed to CodeCommit"

# =============================================================================
# Trigger the pipeline
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Triggering CodePipeline..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

AWS_REGION="${AWS_REGION:-us-east-1}"
PIPELINE_NAME=$(aws codepipeline list-pipelines --query "pipelines[?contains(name, 'Workshop') || contains(name, 'DevOps')].name" --output text --region $AWS_REGION | head -1)

if [ -z "$PIPELINE_NAME" ]; then
    echo "   ⚠️  Could not find pipeline - it may trigger automatically from git push"
else
    echo "   Found pipeline: $PIPELINE_NAME"
    EXECUTION_ID=$(aws codepipeline start-pipeline-execution --name "$PIPELINE_NAME" --query 'pipelineExecutionId' --output text --region $AWS_REGION)
    echo "   ✅ Pipeline triggered: $EXECUTION_ID"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ SCENARIO 3 INJECTION COMPLETE                                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "⏳ Pipeline is building and deploying..."
echo "   This typically takes 10-15 minutes."
echo ""
echo "⚠️  After deployment, the service will work normally but CloudWatch"
echo "   logs will contain sensitive data that should never be logged!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 DevOps Agent Investigation Prompt:"
echo ""
echo "   'Check the CloudWatch logs for the PetSearch service."
echo "    I'm concerned there might be sensitive data being logged."
echo "    Can you investigate and identify any security issues?'"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🛠️  To fix: ./workshop-scenarios/scenario3-security-issue/fix.sh"
