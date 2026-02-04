#!/bin/bash
# Update CodePipeline to use GitHub source instead of S3

set -e

PIPELINE_NAME="DevOpsAgent-Pipeline-Workshop-Pipeline-0NHaleIMiheT"
CONNECTION_ARN="arn:aws:codestar-connections:us-east-1:466162272783:connection/71748461-6289-4e0b-8e59-18db7df288af"
GITHUB_REPO="shyamkulkarni/devops-agent-pipeline-integration"
BRANCH="main"
REGION="us-east-1"

echo "Fetching current pipeline configuration..."
aws codepipeline get-pipeline --name "$PIPELINE_NAME" --region "$REGION" > /tmp/pipeline.json

echo "Creating updated pipeline configuration..."
cat > /tmp/updated-pipeline.json << 'EOF'
{
  "pipeline": {
    "name": "DevOpsAgent-Pipeline-Workshop-Pipeline-0NHaleIMiheT",
    "roleArn": "arn:aws:iam::466162272783:role/DevOpsAgent-Pipeline-Workshop-PipelineRole-jZmL6aSWD6ns",
    "artifactStore": {
      "type": "S3",
      "location": "devopsagent-pipeline-works-pipelineartifactsbucket-9bwfokrkaxxd"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "GitHubSource",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "CodeStarSourceConnection",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ConnectionArn": "arn:aws:codestar-connections:us-east-1:466162272783:connection/71748461-6289-4e0b-8e59-18db7df288af",
              "FullRepositoryId": "shyamkulkarni/devops-agent-pipeline-integration",
              "BranchName": "main",
              "OutputArtifactFormat": "CODE_ZIP",
              "DetectChanges": "true"
            },
            "outputArtifacts": [
              {
                "name": "SourceOutput"
              }
            ],
            "inputArtifacts": []
          }
        ]
      },
      {
        "name": "Build",
        "actions": [
          {
            "name": "BuildPetSearch",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ProjectName": "PipelineDeployProject-1ARrEM983PUm"
            },
            "outputArtifacts": [
              {
                "name": "BuildOutput"
              }
            ],
            "inputArtifacts": [
              {
                "name": "SourceOutput"
              }
            ]
          }
        ]
      }
    ],
    "version": 2,
    "executionMode": "SUPERSEDED",
    "pipelineType": "V2"
  }
}
EOF

echo "Updating pipeline..."
aws codepipeline update-pipeline --cli-input-json file:///tmp/updated-pipeline.json --region "$REGION"

echo ""
echo "✅ Pipeline updated to use GitHub source!"
echo "   Repository: $GITHUB_REPO"
echo "   Branch: $BRANCH"
echo ""
echo "The pipeline will now trigger automatically on GitHub pushes."
