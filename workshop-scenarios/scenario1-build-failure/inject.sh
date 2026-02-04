#!/bin/bash
# Scenario 1: Build Failure - Dependency Version Conflict
# A developer adds a "performance optimization" library that pulls in
# an incompatible older version of a core dependency

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_GRADLE="$REPO_ROOT/PetAdoptions/petsearch-java/build.gradle"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 1: Build Failure - Dependency Version Conflict         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Story: A developer adds a caching library for 'performance optimization'"
echo "         but it pulls in an incompatible older Servlet API version"
echo ""

# Backup original file
cp "$BUILD_GRADLE" "$BUILD_GRADLE.backup"

# Add a dependency that forces an old servlet-api version incompatible with Spring Boot 3.x
# Spring Boot 3.x requires Jakarta Servlet 6.0, but this pulls in javax.servlet 3.x
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "/implementation 'org.springframework.boot:spring-boot-starter-web'/a\\
    implementation 'org.ehcache:ehcache:3.8.1'\\
    implementation 'javax.servlet:javax.servlet-api:3.1.0'
" "$BUILD_GRADLE"
else
    sed -i "/implementation 'org.springframework.boot:spring-boot-starter-web'/a\\
    implementation 'org.ehcache:ehcache:3.8.1'\\
    implementation 'javax.servlet:javax.servlet-api:3.1.0'
" "$BUILD_GRADLE"
fi

echo "✅ Injection complete!"
echo ""
echo "📁 Modified: PetAdoptions/petsearch-java/build.gradle"
echo "   Added: ehcache 3.8.1 (caching library)"
echo "   Added: javax.servlet-api 3.1.0 (transitive conflict)"
echo ""
echo "   Problem: Spring Boot 3.x uses Jakarta EE 9+ (jakarta.servlet.*)"
echo "            but javax.servlet-api uses old namespace (javax.servlet.*)"
echo "            This causes class conflicts during compilation"
echo ""

# Auto commit, push, and trigger pipeline
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 Committing and pushing changes..."
echo ""

cd "$REPO_ROOT"

# Ensure PATH includes git-remote-codecommit
export PATH="$PATH:$HOME/Library/Python/3.9/bin:$HOME/.local/bin"

git add PetAdoptions/petsearch-java/build.gradle
git commit -m "perf: add ehcache for improved response times"
git push origin main

echo ""
echo "✅ Changes pushed to CodeCommit"
echo ""

# Get pipeline name and trigger
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Triggering pipeline..."
echo ""

PIPELINE_NAME=$(aws cloudformation describe-stacks \
    --stack-name DevOpsAgent-Pipeline-Workshop \
    --region us-east-1 \
    --query "Stacks[0].Outputs[?OutputKey=='PipelineName'].OutputValue" \
    --output text 2>/dev/null)

if [ -n "$PIPELINE_NAME" ]; then
    aws codepipeline start-pipeline-execution --name "$PIPELINE_NAME" --region us-east-1
    echo "✅ Pipeline triggered: $PIPELINE_NAME"
    echo ""
    echo "📊 Monitor pipeline status:"
    echo "   aws codepipeline get-pipeline-state --name $PIPELINE_NAME --region us-east-1 \\"
    echo "       --query 'stageStates[*].[stageName,latestExecution.status]' --output table"
else
    echo "⚠️  Could not find pipeline. Trigger manually:"
    echo "   aws codepipeline start-pipeline-execution --name <PIPELINE_NAME> --region us-east-1"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 DevOps Agent Investigation Prompt:"
echo ""
echo "   'The PetSearch service build is failing with strange errors about"
echo "    servlet classes. The error mentions jakarta.servlet but also"
echo "    javax.servlet. What's causing this conflict?'"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🛠️  To fix: ./workshop-scenarios/scenario1-build-failure/fix.sh"
