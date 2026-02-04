#!/bin/bash
# Scenario 3: Fix - Remove Sensitive Data Logging + Deploy
# This script restores the original SearchController.java and triggers deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Generate timestamp to force CDK rebuild (content-based hashing)
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 3: Fix - Remove Sensitive Data Logging + Deploy        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 1: Restore the original SearchController.java
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 STEP 1: Restoring original SearchController.java"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Note: Using variable substitution for BUILD_TIMESTAMP to force CDK rebuild
cat > "$CONTROLLER" << JAVAEOF
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
    // Build timestamp: ${BUILD_TIMESTAMP} - Force CDK rebuild
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

# Remove backup if it exists
rm -f "$CONTROLLER.backup"

echo "   ✅ Restored original SearchController.java"

# =============================================================================
# STEP 2: Commit and push to CodeCommit
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 STEP 2: Committing and pushing to CodeCommit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$REPO_ROOT"

# Configure CodeCommit remote if not already set
CODECOMMIT_URL=$(aws cloudformation describe-stacks \
    --query "Stacks[?contains(StackName, 'Pipeline') || contains(StackName, 'Workshop')].Outputs[?OutputKey=='CodeCommitRepoCloneUrlHttp'].OutputValue" \
    --output text --region $AWS_REGION 2>/dev/null | head -1)

if [ -n "$CODECOMMIT_URL" ]; then
    git remote set-url origin "$CODECOMMIT_URL" 2>/dev/null || git remote add origin "$CODECOMMIT_URL"
fi

git add PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java

if git diff --cached --quiet; then
    echo "   ℹ️  No changes to commit (already fixed)"
else
    git commit -m "security: remove debug logging that exposes sensitive data"
    echo "   ✅ Changes committed"
fi

git push origin main
echo "   ✅ Pushed to CodeCommit"

# =============================================================================
# STEP 3: Trigger the pipeline
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 STEP 3: Triggering CodePipeline"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Find the pipeline
PIPELINE_NAME=$(aws codepipeline list-pipelines --query "pipelines[?contains(name, 'Workshop') || contains(name, 'DevOps')].name" --output text --region $AWS_REGION | head -1)

if [ -z "$PIPELINE_NAME" ]; then
    echo "   ⚠️  Could not find pipeline - it may trigger automatically from git push"
else
    echo "   Found pipeline: $PIPELINE_NAME"
    EXECUTION_ID=$(aws codepipeline start-pipeline-execution --name "$PIPELINE_NAME" --query 'pipelineExecutionId' --output text --region $AWS_REGION)
    echo "   ✅ Pipeline triggered: $EXECUTION_ID"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ FIX INITIATED                                                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔐 Security Issues Removed:"
echo "   ✓ Removed logging of HTTP headers (Authorization, Cookie, etc.)"
echo "   ✓ Removed logging of internal AWS resource names"
echo "   ✓ Removed logging of SSM parameter values"
echo "   ✓ Removed logging of S3 presigned URLs"
echo ""
echo "⏳ Pipeline is building and deploying the fix..."
echo "   This typically takes 10-15 minutes."
echo ""
echo "   Monitor: https://console.aws.amazon.com/codesuite/codepipeline/pipelines"
