#!/bin/bash
# Scenario 6: Race Condition - Intermittent Failures
# This script injects code that causes random failures due to thread-unsafe operations
#
# DevOps Agent GitHub Integration Demo:
# - Service deploys successfully
# - Random 500 errors appear under concurrent load (5-15% of requests)
# - Errors are intermittent and hard to reproduce
# - Agent correlates error pattern with deployment and identifies unsafe code

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTROLLER="$REPO_ROOT/PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 6: Race Condition - Intermittent Failures              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"


# Backup original file
cp "$CONTROLLER" "$CONTROLLER.backup"

# Create the modified controller with race condition
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
    
    private static final Map<String, Integer> requestCountByPetType = new HashMap<>();
    private static final Map<String, Long> lastAccessTime = new HashMap<>();
    private static final List<String> recentSearches = new ArrayList<>();

    public SearchController(AmazonS3 s3Client, AmazonDynamoDB ddbClient, AWSSimpleSystemsManagement ssmClient, MetricEmitter metricEmitter, Tracer tracer, RandomNumberGenerator randomGenerator) {
        this.s3Client = s3Client;
        this.ddbClient = ddbClient;
        this.ssmClient = ssmClient;
        this.metricEmitter = metricEmitter;
        this.tracer = tracer;
        this.randomGenerator = randomGenerator;
    }
    
    private void trackSearchAnalytics(String petType, String petColor) {
        String searchKey = petType + "-" + petColor;
        
        Integer currentCount = requestCountByPetType.get(petType);
        if (currentCount == null) {
            currentCount = 0;
        }
        requestCountByPetType.put(petType, currentCount + 1);
        
        lastAccessTime.put(searchKey, System.currentTimeMillis());
        
        recentSearches.add(searchKey);
        
        if (recentSearches.size() > 100) {
            logger.info("Cleaning up old searches, current analytics:");
            int totalSearches = 0;
            for (Map.Entry<String, Integer> entry : requestCountByPetType.entrySet()) {
                logger.debug("  " + entry.getKey() + ": " + entry.getValue() + " searches");
                totalSearches += entry.getValue();
            }
            logger.info("Total searches tracked: " + totalSearches);
            
            recentSearches.clear();
        }
    }
    
    private String getAnalyticsSummary() {
        StringBuilder sb = new StringBuilder();
        sb.append("Search Analytics: ");
        
        for (String petType : requestCountByPetType.keySet()) {
            Integer count = requestCountByPetType.get(petType);
            sb.append(petType).append("=").append(count).append(" ");
        }
        
        return sb.toString();
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
        
        trackSearchAnalytics(petType, petColor);
        
        if (Math.random() < 0.1) {
            logger.info(getAnalyticsSummary());
        }
        
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

echo "✅ Injection complete!"
echo ""
echo "📁 Modified: PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java"
echo "   Added: Non-thread-safe HashMap for request tracking"
echo "   Added: Non-thread-safe ArrayList for recent searches"
echo "   Added: Concurrent iteration and modification patterns"
echo "   Problem: Random ConcurrentModificationException and NullPointerException"
echo ""

# =============================================================================
# Auto-commit and push to CodeCommit
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 Committing and pushing to CodeCommit..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$REPO_ROOT"
git add PetAdoptions/petsearch-java/src/main/java/ca/petsearch/controllers/SearchController.java
git commit -m "feat: add search analytics tracking for business insights" 2>/dev/null || echo "   (No changes to commit)"
git push origin main

echo ""
echo "✅ Changes pushed to CodeCommit - pipeline will trigger automatically"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  The pipeline will SUCCEED, and the service will MOSTLY work:"
echo ""
echo "   • 85-95% of requests succeed normally"
echo "   • 5-15% of requests fail with random errors:"
echo "     - java.util.ConcurrentModificationException"
echo "     - java.lang.NullPointerException"
echo "   • Errors appear random and unreproducible"
echo "   • Error rate increases with traffic"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 DevOps Agent Investigation Prompt:"
echo ""
echo "   'We're seeing intermittent 500 errors on the PetSearch service."
echo "    About 10% of requests fail with different exceptions each time:"
echo "    ConcurrentModificationException and NullPointerException."
echo "    The errors started after a recent deployment but we cannot"
echo "    reproduce them locally. Investigate the recent code changes"
echo "    to identify potential thread-safety issues.'"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 What DevOps Agent will find:"
echo ""
echo "   • Correlates error spike timing with deployment"
echo "   • Identifies the commit that added 'analytics' code"
echo "   • Detects non-thread-safe HashMap/ArrayList usage"
echo "   • Points to concurrent read/write patterns"
echo "   • Recommends ConcurrentHashMap or synchronization"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🛠️  To fix: ./workshop-scenarios/scenario6-race-condition/fix.sh"
