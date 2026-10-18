#!/bin/bash
set -e
export $(grep -v '^#' .env | xargs)

# Load resource identifiers created by the deployment script
if [ -f stack_outputs.env ]; then
  set -a
  source stack_outputs.env
  set +a
fi

echo "== Deleting Auto Scaling Groups =="

for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do
  EXISTING=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$AWS_REGION" \
    --query "AutoScalingGroups[0].AutoScalingGroupName" \
    --output text)

  if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "Deleting $ASG_NAME..."

    aws autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name "$ASG_NAME" \
      --force-delete \
      --region "$AWS_REGION"
  else
    echo "$ASG_NAME does not exist."
  fi
done

echo "== Waiting for Auto Scaling Groups to be deleted =="

for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do
  DELETED=false

  for i in $(seq 1 40); do
    EXISTING=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$AWS_REGION" \
      --query "AutoScalingGroups[0].AutoScalingGroupName" \
      --output text)

    if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
      echo "$ASG_NAME deleted."
      DELETED=true
      break
    fi

    echo "Waiting for $ASG_NAME..."
    sleep 15
  done

  if [ "$DELETED" != true ]; then
    echo "ERROR: $ASG_NAME was not deleted within the timeout."
    exit 1
  fi
done

echo "Both Auto Scaling Groups have been deleted."


echo "== Waiting for ASG EC2 instances to terminate =="

aws ec2 wait instance-terminated \
  --instance-ids \
  i-0af3de0f7877748e4 \
  i-079d3a2e0df882605 \
  --region "$AWS_REGION"

echo "ASG instances terminated."

echo "== Deleting Application Load Balancer =="

if [ -n "${ALB_ARN:-}" ]; then
  aws elbv2 delete-load-balancer \
    --load-balancer-arn "$ALB_ARN" \
    --region "$AWS_REGION"

  echo "Waiting for ALB deletion..."
  aws elbv2 wait load-balancers-deleted \
    --load-balancer-arns "$ALB_ARN" \
    --region "$AWS_REGION"
else
  echo "WARNING: ALB ARN missing; cleanup needs verification."
fi

echo "== Deleting Target Groups =="

for TG_ARN in "${UPLOADER_TG_ARN:-}" "${VIEWER_TG_ARN:-}"; do
  if [ -n "$TG_ARN" ]; then
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$AWS_REGION"
  fi
done

echo "== Cleaning up security groups =="

if [ -n "${ALB_SECURITY_GROUP_ID:-}" ]; then
  aws ec2 revoke-security-group-ingress \
    --group-id "$APP_SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 3000 \
    --source-group "$ALB_SECURITY_GROUP_ID" \
    --region "$AWS_REGION" 2>/dev/null || true

  aws ec2 delete-security-group \
    --group-id "$ALB_SECURITY_GROUP_ID" \
    --region "$AWS_REGION"

  echo "ALB security group deleted."
else
  echo "WARNING: ALB security group ID missing; cleanup needs verification."
fi

echo "Deleting launch templates..."
aws ec2 delete-launch-template --launch-template-name "$UPLOADER_LT_NAME" --region "$AWS_REGION" 2>/dev/null || true
aws ec2 delete-launch-template --launch-template-name "$VIEWER_LT_NAME" --region "$AWS_REGION" 2>/dev/null || true

echo "Removing IAM instance profiles and roles..."

aws iam remove-role-from-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$UPLOADER_ROLE_NAME" --policy-name "uploader-put-only" 2>/dev/null || true
aws iam delete-role --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true

aws iam remove-role-from-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$VIEWER_ROLE_NAME" --policy-name "${VIEWER_ROLE_NAME}-policy" 2>/dev/null || true
aws iam delete-role --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
echo "Emptying and deleting S3 bucket..."
aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true
echo "Cleanup complete."
