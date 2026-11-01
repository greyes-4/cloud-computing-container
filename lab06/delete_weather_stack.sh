#!/bin/bash
set -uo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"

[ -f stack_outputs.env ] && source stack_outputs.env

echo "== 1. Delete Auto Scaling Groups =="
for ASG in "$WEATHER_ASG_NAME" "$ADVISOR_ASG_NAME"; do
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$ASG" \
    --force-delete 2>/dev/null || true
done

echo "== 2. Wait for Auto Scaling Groups to disappear =="
for ASG in "$WEATHER_ASG_NAME" "$ADVISOR_ASG_NAME"; do
  for i in $(seq 1 20); do
    RESULT=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].AutoScalingGroupName' \
      --output text 2>/dev/null || true)

    if [ -z "$RESULT" ] || [ "$RESULT" = "None" ]; then
      echo "$ASG removed."
      break
    fi

    sleep 15
  done
done

echo "== 3. Delete the load balancer and target groups =="
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
  aws elbv2 wait load-balancers-deleted \
    --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
fi

for TG in "$WEATHER_TG_NAME" "$ADVISOR_TG_NAME"; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" || true
  fi
done

echo "== 4. Remove ALB security group rules =="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [ -n "$ALB_SG" ] && [ "$ALB_SG" != "None" ]; then
  aws ec2 revoke-security-group-ingress \
    --group-id "$APP_SECURITY_GROUP_ID" \
    --protocol tcp --port 3000 \
    --source-group "$ALB_SG" >/dev/null 2>&1 || true

  for i in $(seq 1 10); do
    if aws ec2 delete-security-group --group-id "$ALB_SG" 2>/dev/null; then
      echo "ALB security group deleted."
      break
    fi
    echo "ALB network interfaces still releasing..."
    sleep 15
  done
fi

echo "== 5. Delete launch templates =="
aws ec2 delete-launch-template \
  --launch-template-name "$WEATHER_LT_NAME" >/dev/null 2>&1 || true
aws ec2 delete-launch-template \
  --launch-template-name "$ADVISOR_LT_NAME" >/dev/null 2>&1 || true

echo "== 6. Delete IAM instance profiles and roles =="
for PAIR in "$WEATHER_ROLE_NAME:$WEATHER_PROFILE_NAME" "$ADVISOR_ROLE_NAME:$ADVISOR_PROFILE_NAME"; do
  ROLE="${PAIR%%:*}"
  PROFILE="${PAIR#*:}"

  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE" \
    --role-name "$ROLE" 2>/dev/null || true

  aws iam delete-instance-profile \
    --instance-profile-name "$PROFILE" 2>/dev/null || true

  for POLICY in "${ROLE}-policy" WeatherDbPasswordAccess AdvisorGeminiKeyAccess; do
    aws iam delete-role-policy \
      --role-name "$ROLE" \
      --policy-name "$POLICY" 2>/dev/null || true
  done

  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
done

rm -f stack_outputs.env
echo "Weather stack cleanup attempted."
echo "Verify AWS resources are deleted before considering cleanup complete."
echo "The RDS database must be deleted separately."
