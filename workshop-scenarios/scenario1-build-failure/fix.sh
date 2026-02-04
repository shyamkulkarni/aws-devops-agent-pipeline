#!/bin/bash
# Scenario 1 Fix: Remove incompatible dependencies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_GRADLE="$REPO_ROOT/PetAdoptions/petsearch-java/build.gradle"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Scenario 1 Fix: Remove Incompatible Dependencies                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Remove the problematic dependencies (pattern matches with any leading whitespace)
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "/org.ehcache:ehcache:3.8.1/d" "$BUILD_GRADLE"
    sed -i '' "/javax.servlet:javax.servlet-api:3.1.0/d" "$BUILD_GRADLE"
else
    sed -i "/org.ehcache:ehcache:3.8.1/d" "$BUILD_GRADLE"
    sed -i "/javax.servlet:javax.servlet-api:3.1.0/d" "$BUILD_GRADLE"
fi

echo "✅ Fix applied!"
echo ""
echo "📁 Modified: PetAdoptions/petsearch-java/build.gradle"
echo "   Removed: ehcache 3.8.1"
echo "   Removed: javax.servlet-api 3.1.0"
echo ""

# Auto commit, push, and trigger pipeline
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 Committing and pushing fix..."
echo ""

cd "$REPO_ROOT"

# Ensure PATH includes git-remote-codecommit
export PATH="$PATH:$HOME/Library/Python/3.9/bin:$HOME/.local/bin"

git add PetAdoptions/petsearch-java/build.gradle
git commit -m "fix: remove incompatible servlet-api dependency"
git push origin main

echo ""
echo "✅ Fix pushed to CodeCommit"
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
echo "✅ Build should now succeed!"
