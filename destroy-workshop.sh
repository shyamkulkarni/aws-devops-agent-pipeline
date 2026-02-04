#!/bin/bash
# =============================================================================
# Destroy One Observability Workshop - Complete Cleanup
# =============================================================================
# Deletes ALL workshop stacks and their dependencies in one shot.
# Order: Applications → Services → DevOpsAgent-Pipeline-Workshop
# 
# Key improvements:
# - Handles EKS custom resource failures by retaining stuck resources
# - Deletes EKS clusters BEFORE stack deletion to avoid Lambda timeouts
# - Automatically detects and retains failed custom resources
# =============================================================================

set -e

# Disable AWS CLI pager to prevent script from hanging
export AWS_PAGER=""

REGION="${AWS_REGION:-us-east-1}"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Destroy One Observability Workshop - Complete Cleanup           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Region: $REGION"
echo ""

# =============================================================================
# Delete EKS cluster completely (before stack deletion)
# =============================================================================
delete_eks_cluster() {
    local cluster_name=$1
    [ -z "$cluster_name" ] && return 0
    
    echo "   🔥 Deleting EKS cluster: $cluster_name"
    
    # 1. Delete all Fargate profiles
    for fp in $(aws eks list-fargate-profiles --cluster-name "$cluster_name" --region "$REGION" --query 'fargateProfileNames[*]' --output text 2>/dev/null); do
        echo "      Deleting Fargate profile: $fp"
        aws eks delete-fargate-profile --cluster-name "$cluster_name" --fargate-profile-name "$fp" --region "$REGION" 2>/dev/null || true
    done
    
    # 2. Delete all nodegroups
    for ng in $(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$REGION" --query 'nodegroups[*]' --output text 2>/dev/null); do
        echo "      Deleting nodegroup: $ng"
        aws eks delete-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
    done
    
    # 3. Delete all addons
    for addon in $(aws eks list-addons --cluster-name "$cluster_name" --region "$REGION" --query 'addons[*]' --output text 2>/dev/null); do
        echo "      Deleting addon: $addon"
        aws eks delete-addon --cluster-name "$cluster_name" --addon-name "$addon" --region "$REGION" 2>/dev/null || true
    done
    
    # 4. Wait for nodegroups to be deleted (they take longest)
    echo "      Waiting for nodegroups to delete..."
    local wait_count=0
    while [ $wait_count -lt 60 ]; do
        local remaining=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$REGION" --query 'nodegroups' --output text 2>/dev/null || echo "")
        if [ -z "$remaining" ]; then
            break
        fi
        sleep 10
        wait_count=$((wait_count + 1))
        echo "      Still waiting... (${wait_count}0s)"
    done
    
    # 5. Delete the cluster itself
    echo "      Deleting cluster..."
    aws eks delete-cluster --name "$cluster_name" --region "$REGION" 2>/dev/null || true
    
    # 6. Wait for cluster deletion
    echo "      Waiting for cluster deletion..."
    aws eks wait cluster-deleted --name "$cluster_name" --region "$REGION" 2>/dev/null || true
    
    echo "   ✅ EKS cluster $cluster_name deleted"
}

# =============================================================================
# Nuke all VPC dependencies
# =============================================================================
nuke_vpc() {
    local vpc_id=$1
    [ -z "$vpc_id" ] || [ "$vpc_id" == "None" ] && return 0
    
    echo "   🔥 Nuking VPC: $vpc_id"
    
    # 1. VPC Endpoints
    for ep in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null); do
        echo "      Deleting VPC endpoint: $ep"
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" --region "$REGION" 2>/dev/null || true
    done
    
    # 2. ECS Services (scale down and delete)
    for ecs_cluster in $(aws ecs list-clusters --region "$REGION" --query 'clusterArns[*]' --output text 2>/dev/null); do
        for svc in $(aws ecs list-services --cluster "$ecs_cluster" --region "$REGION" --query 'serviceArns[*]' --output text 2>/dev/null); do
            echo "      Deleting ECS service: $(basename $svc)"
            aws ecs update-service --cluster "$ecs_cluster" --service "$svc" --desired-count 0 --region "$REGION" 2>/dev/null || true
            aws ecs delete-service --cluster "$ecs_cluster" --service "$svc" --force --region "$REGION" 2>/dev/null || true
        done
    done
    
    # 3. Load Balancers
    for lb in $(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null); do
        echo "      Deleting load balancer: $(basename $lb)"
        aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region "$REGION" 2>/dev/null || true
    done
    
    # 4. Target Groups
    for tg in $(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?VpcId=='$vpc_id'].TargetGroupArn" --output text 2>/dev/null); do
        aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" 2>/dev/null || true
    done
    
    # 5. NAT Gateways
    for nat in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null); do
        echo "      Deleting NAT gateway: $nat"
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null || true
    done
    
    # 6. Internet Gateways
    for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --region "$REGION" --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
        echo "      Detaching/deleting IGW: $igw"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
    done
    
    # 7. RDS instances
    for rds in $(aws rds describe-db-instances --region "$REGION" --query "DBInstances[?DBSubnetGroup.VpcId=='$vpc_id'].DBInstanceIdentifier" --output text 2>/dev/null); do
        echo "      Deleting RDS: $rds"
        aws rds delete-db-instance --db-instance-identifier "$rds" --skip-final-snapshot --delete-automated-backups --region "$REGION" 2>/dev/null || true
    done
    
    # Wait for NAT gateways
    sleep 30
    
    # 8. Network Interfaces (ENIs)
    for eni in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
        local attachment=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "")
        if [ -n "$attachment" ] && [ "$attachment" != "None" ]; then
            aws ec2 detach-network-interface --attachment-id "$attachment" --force --region "$REGION" 2>/dev/null || true
            sleep 3
        fi
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
    done
    
    # 9. Subnets
    for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
        echo "      Deleting subnet: $subnet"
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null || true
    done
    
    # 10. Security Groups (except default)
    for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
        echo "      Deleting security group: $sg"
        aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$REGION" --ip-permissions "$(aws ec2 describe-security-groups --group-ids $sg --region $REGION --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
        aws ec2 revoke-security-group-egress --group-id "$sg" --region "$REGION" --ip-permissions "$(aws ec2 describe-security-groups --group-ids $sg --region $REGION --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
        aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
    done
    
    # 11. Route Tables
    for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null); do
        for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$REGION" --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
            aws ec2 disassociate-route-table --association-id "$assoc" --region "$REGION" 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done
    
    # 12. Network ACLs (except default)
    for nacl in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NetworkAcls[?IsDefault!=`true`].NetworkAclId' --output text 2>/dev/null); do
        aws ec2 delete-network-acl --network-acl-id "$nacl" --region "$REGION" 2>/dev/null || true
    done
    
    # 13. VPC Peering
    for pcx in $(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$vpc_id" --region "$REGION" --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
        aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx" --region "$REGION" 2>/dev/null || true
    done
    
    # 14. Elastic IPs
    for eip in $(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[?AssociationId==`null`].AllocationId' --output text 2>/dev/null); do
        aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
    done
    
    # 15. Delete VPC
    echo "      Deleting VPC: $vpc_id"
    aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null || true
}

# =============================================================================
# Get failed resources from a stack (for --retain-resources)
# =============================================================================
get_failed_resources() {
    local stack_name=$1
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].LogicalResourceId' \
        --output text 2>/dev/null | tr '\t' ' ' | tr '\n' ' ' | xargs
}

# =============================================================================
# Delete stack with automatic retry and retain-resources for failures
# =============================================================================
delete_stack() {
    local stack_name=$1
    local timeout=${2:-1800}
    local max_retries=3
    local retry=0
    
    local status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$status" == "NOT_FOUND" ] || [ "$status" == "DELETE_COMPLETE" ]; then
        echo "   ⏭️  Stack $stack_name not found, skipping"
        return 0
    fi
    
    # Get VPCs from this stack for pre-cleanup
    local vpcs=$(aws cloudformation describe-stack-resources --stack-name "$stack_name" --region "$REGION" --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' --output text 2>/dev/null || echo "")
    
    # For Services stack: Delete EKS clusters FIRST (before stack deletion)
    # This prevents Lambda custom resource timeouts
    if [ "$stack_name" == "Services" ]; then
        echo "   🔍 Looking for EKS clusters to delete first..."
        for cluster in $(aws eks list-clusters --region "$REGION" --query 'clusters[*]' --output text 2>/dev/null); do
            # Check if cluster belongs to this VPC
            for vpc in $vpcs; do
                local cvpc=$(aws eks describe-cluster --name "$cluster" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
                if [ "$cvpc" == "$vpc" ]; then
                    delete_eks_cluster "$cluster"
                fi
            done
        done
    fi
    
    # Pre-nuke VPC dependencies
    for vpc in $vpcs; do
        nuke_vpc "$vpc"
    done
    
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        echo "   🗑️  Deleting stack: $stack_name (attempt $retry/$max_retries)"
        
        # Check if stack is in DELETE_FAILED state - need to use --retain-resources
        status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
        
        if [ "$status" == "DELETE_FAILED" ]; then
            local failed_resources=$(get_failed_resources "$stack_name")
            if [ -n "$failed_resources" ]; then
                echo "   ⚠️  Stack in DELETE_FAILED state. Retaining failed resources: $failed_resources"
                aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" --retain-resources $failed_resources 2>/dev/null || true
            else
                aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" 2>/dev/null || true
            fi
        else
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" 2>/dev/null || true
        fi
        
        echo "   ⏳ Waiting for deletion..."
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            sleep 20
            elapsed=$((elapsed + 20))
            
            status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")
            
            if [ "$status" == "DELETE_COMPLETE" ] || [ "$status" == "NOT_FOUND" ]; then
                echo "   ✅ $stack_name deleted"
                return 0
            elif [ "$status" == "DELETE_FAILED" ]; then
                echo "   ⚠️  DELETE_FAILED - will retry with --retain-resources"
                # Re-nuke dependencies before retry
                for vpc in $vpcs; do nuke_vpc "$vpc"; done
                break
            else
                echo "      $status (${elapsed}s)"
            fi
        done
        
        if [ "$status" != "DELETE_FAILED" ]; then
            echo "   ⚠️  Timeout waiting for deletion"
        fi
    done
    
    # Final attempt: force retain all failed resources
    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")
    if [ "$status" == "DELETE_FAILED" ]; then
        local failed_resources=$(get_failed_resources "$stack_name")
        if [ -n "$failed_resources" ]; then
            echo "   🔧 Final attempt: retaining all failed resources"
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" --retain-resources $failed_resources 2>/dev/null || true
            sleep 30
            status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")
            if [ "$status" == "DELETE_COMPLETE" ] || [ "$status" == "NOT_FOUND" ]; then
                echo "   ✅ $stack_name deleted (with retained resources)"
                return 0
            fi
        fi
    fi
    
    echo "   ❌ Failed to delete $stack_name after $max_retries attempts"
    return 1
}

# =============================================================================
# Delete nested stacks first (they can block parent deletion)
# =============================================================================
delete_nested_stacks() {
    local parent_stack=$1
    
    echo "   🔍 Looking for nested stacks of $parent_stack..."
    
    # Find nested stacks
    local nested=$(aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
        --query "StackSummaries[?contains(StackName, '$parent_stack') && StackName!='$parent_stack'].StackName" \
        --output text 2>/dev/null)
    
    for nested_stack in $nested; do
        echo "   📦 Found nested stack: $nested_stack"
        delete_stack "$nested_stack" 600
    done
}

# =============================================================================
# Main
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1/3: Applications"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
delete_nested_stacks "Applications"
delete_stack "Applications" 1800

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2/3: Services (includes EKS - may take 15-20 minutes)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
delete_nested_stacks "Services"
delete_stack "Services" 2400

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3/3: DevOpsAgent-Pipeline-Workshop"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Pre-cleanup orphaned ENIs
PIPELINE_VPC=$(aws cloudformation describe-stack-resources --stack-name "DevOpsAgent-Pipeline-Workshop" --region "$REGION" --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' --output text 2>/dev/null || echo "")
if [ -n "$PIPELINE_VPC" ] && [ "$PIPELINE_VPC" != "None" ]; then
    echo "   🔍 Cleaning up orphaned ENIs in VPC: $PIPELINE_VPC"
    for eni in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$PIPELINE_VPC" --region "$REGION" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
        echo "      Deleting ENI: $eni"
        attachment=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "")
        if [ -n "$attachment" ] && [ "$attachment" != "None" ]; then
            aws ec2 detach-network-interface --attachment-id "$attachment" --force --region "$REGION" 2>/dev/null || true
            sleep 3
        fi
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
    done
fi

delete_stack "DevOpsAgent-Pipeline-Workshop" 900

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup: Orphaned resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# S3 buckets
for b in $(aws s3api list-buckets --query 'Buckets[?contains(Name,`pipeline`)||contains(Name,`cdk`)||contains(Name,`petadoption`)].Name' --output text 2>/dev/null); do
    echo "   S3: $b"
    aws s3 rm "s3://$b" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null || true
done

# ECR repositories
for r in $(aws ecr describe-repositories --region "$REGION" --query 'repositories[?contains(repositoryName,`pet`)||contains(repositoryName,`cdk`)].repositoryName' --output text 2>/dev/null); do
    echo "   ECR: $r"
    aws ecr delete-repository --repository-name "$r" --force --region "$REGION" 2>/dev/null || true
done

# CloudWatch Log Groups
for lg in $(aws logs describe-log-groups --region "$REGION" --query 'logGroups[?contains(logGroupName,`/ecs/Pet`)||contains(logGroupName,`/codebuild/`)||contains(logGroupName,`/aws/eks`)].logGroupName' --output text 2>/dev/null); do
    echo "   Logs: $lg"
    aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null || true
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ CLEANUP COMPLETE                                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
