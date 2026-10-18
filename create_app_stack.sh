#!/bin/bash
set -e
export $(grep -v '^#' .env | xargs)

echo "== S3 bucket =="

if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    echo "Bucket already exists, skipping."
else
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

echo "== Creating IAM trust policy =="

cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "== Uploader role =="

aws iam create-role \
  --role-name "$UPLOADER_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json \
  2>/dev/null || echo "Uploader role already exists."

cat > uploader-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$UPLOADER_ROLE_NAME" \
  --policy-name "uploader-put-only" \
  --policy-document file://uploader-policy.json

aws iam create-instance-profile \
  --instance-profile-name "$UPLOADER_PROFILE_NAME" \
  2>/dev/null || echo "Uploader profile already exists."

aws iam add-role-to-instance-profile \
  --instance-profile-name "$UPLOADER_PROFILE_NAME" \
  --role-name "$UPLOADER_ROLE_NAME" \
  2>/dev/null || true

echo "== Viewer role =="

aws iam create-role \
  --role-name "$VIEWER_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json \
  2>/dev/null || echo "Viewer role already exists."

cat > viewer-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$VIEWER_ROLE_NAME" \
  --policy-name "${VIEWER_ROLE_NAME}-policy" \
  --policy-document file://viewer-policy.json

aws iam create-instance-profile \
  --instance-profile-name "$VIEWER_PROFILE_NAME" \
  2>/dev/null || echo "Viewer profile already exists."

aws iam add-role-to-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true

echo "== Preparing application user-data =="

UPLOADER_APP_DIR="lab03/uploader-app"
VIEWER_APP_DIR="lab03/viewer-app"

for FILE in \
  "$UPLOADER_APP_DIR/app.js" \
  "$UPLOADER_APP_DIR/package.json" \
  "$VIEWER_APP_DIR/app.js" \
  "$VIEWER_APP_DIR/package.json"; do
    if [[ ! -f "$FILE" ]]; then
        echo "ERROR: Missing $FILE"
        exit 1
    fi
done

UPLOADER_APP_B64=$(base64 -w 0 "$UPLOADER_APP_DIR/app.js")
UPLOADER_PKG_B64=$(base64 -w 0 "$UPLOADER_APP_DIR/package.json")

VIEWER_APP_B64=$(base64 -w 0 "$VIEWER_APP_DIR/app.js")
VIEWER_PKG_B64=$(base64 -w 0 "$VIEWER_APP_DIR/package.json")

echo "Application files encoded successfully."

echo "== Building Uploader user-data =="

cat > user-data-uploader.sh << EOF
#!/bin/bash
set -e

dnf update -y
dnf install -y nodejs

mkdir -p /opt/app

echo "$UPLOADER_APP_B64" | base64 -d > /opt/app/app.js
echo "$UPLOADER_PKG_B64" | base64 -d > /opt/app/package.json

cd /opt/app
npm install --omit=dev

cat > /etc/systemd/system/uploader.service << 'SERVICE'
[Unit]
Description=Uploader App
After=network.target

[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE

chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable uploader.service
systemctl start uploader.service
EOF

echo "== Building Viewer user-data =="

cat > user-data-viewer.sh << EOF
#!/bin/bash
set -e

dnf update -y
dnf install -y nodejs

mkdir -p /opt/app

echo "$VIEWER_APP_B64" | base64 -d > /opt/app/app.js
echo "$VIEWER_PKG_B64" | base64 -d > /opt/app/package.json

cd /opt/app
npm install --omit=dev

cat > /etc/systemd/system/viewer.service << 'SERVICE'
[Unit]
Description=Viewer App
After=network.target

[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE

chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable viewer.service
systemctl start viewer.service
EOF

echo "== Building launch template data =="

UPLOADER_USERDATA_B64=$(base64 -w0 user-data-uploader.sh)
VIEWER_USERDATA_B64=$(base64 -w0 user-data-viewer.sh)

cat > uploader-lt-data.json << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": {
    "Name": "$UPLOADER_PROFILE_NAME"
  },
  "UserData": "$UPLOADER_USERDATA_B64",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {
          "Key": "Name",
          "Value": "uploader-app"
        }
      ]
    }
  ]
}
EOF

cat > viewer-lt-data.json << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": {
    "Name": "$VIEWER_PROFILE_NAME"
  },
  "UserData": "$VIEWER_USERDATA_B64",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {
          "Key": "Name",
          "Value": "viewer-app"
        }
      ]
    }
  ]
}
EOF

echo "== Creating/updating launch templates =="

if aws ec2 describe-launch-templates \
  --launch-template-names "$UPLOADER_LT_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then

    echo "Uploader template exists - creating new version."

    aws ec2 create-launch-template-version \
      --launch-template-name "$UPLOADER_LT_NAME" \
      --source-version 1 \
      --launch-template-data file://uploader-lt-data.json \
      --region "$AWS_REGION"
else
    echo "Creating uploader launch template."

    aws ec2 create-launch-template \
      --launch-template-name "$UPLOADER_LT_NAME" \
      --launch-template-data file://uploader-lt-data.json \
      --region "$AWS_REGION"
fi

if aws ec2 describe-launch-templates \
  --launch-template-names "$VIEWER_LT_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then

    echo "Viewer template exists - creating new version."

    aws ec2 create-launch-template-version \
      --launch-template-name "$VIEWER_LT_NAME" \
      --source-version 1 \
      --launch-template-data file://viewer-lt-data.json \
      --region "$AWS_REGION"
else
    echo "Creating viewer launch template."

    aws ec2 create-launch-template \
      --launch-template-name "$VIEWER_LT_NAME" \
      --launch-template-data file://viewer-lt-data.json \
      --region "$AWS_REGION"
fi

echo "== Looking up the default VPC and subnets in both AZs =="

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region "$AWS_REGION")

SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$AWS_REGION")

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$AWS_REGION")

echo "VPC: $VPC_ID"
echo "$AZ_A subnet: $SUBNET_A"
echo "$AZ_B subnet: $SUBNET_B"

if [[ "$VPC_ID" == "None" || "$SUBNET_A" == "None" || "$SUBNET_B" == "None" || \
      -z "$VPC_ID" || -z "$SUBNET_A" || -z "$SUBNET_B" || "$SUBNET_A" == "$SUBNET_B" ]]; then
    echo "ERROR: Could not find a valid VPC and two different subnets."
    exit 1
fi

echo "== ALB security group =="

ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$AWS_REGION")

if [ "$ALB_SECURITY_GROUP_ID" = "None" ] || [ -z "$ALB_SECURITY_GROUP_ID" ]; then
  ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Allow inbound to the ALB on the app listener ports" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$AWS_REGION")
fi

for PORT in "$UPLOADER_LISTENER_PORT" "$VIEWER_LISTENER_PORT"; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SECURITY_GROUP_ID" \
    --protocol tcp --port "$PORT" \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" >/dev/null 2>&1 || true
done

echo "ALB security group: $ALB_SECURITY_GROUP_ID"

echo "== Tightening the app security group =="

aws ec2 revoke-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 \
  --cidr 0.0.0.0/0 \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 \
  --source-group "$ALB_SECURITY_GROUP_ID" \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

echo "App security group configured for ALB access."

echo "== Target groups =="

UPLOADER_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$UPLOADER_TG_NAME" \
  --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null || true)

if [ "$UPLOADER_TG_ARN" = "None" ] || [ -z "$UPLOADER_TG_ARN" ]; then
  UPLOADER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$UPLOADER_TG_NAME" \
    --protocol HTTP \
    --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
else
  echo "Uploader target group already exists, skipping."
fi

VIEWER_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$VIEWER_TG_NAME" \
  --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null || true)

if [ "$VIEWER_TG_ARN" = "None" ] || [ -z "$VIEWER_TG_ARN" ]; then
  VIEWER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$VIEWER_TG_NAME" \
    --protocol HTTP \
    --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
else
  echo "Viewer target group already exists, skipping."
fi

echo "Uploader target group: $UPLOADER_TG_ARN"
echo "Viewer target group: $VIEWER_TG_ARN"

echo "== Application Load Balancer =="

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SECURITY_GROUP_ID" \
    --scheme internet-facing \
    --type application \
    --region "$AWS_REGION" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)
fi

echo "Waiting for the ALB to become active..."

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"

echo "== Creating ALB listeners =="

EXISTING_PORTS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query "Listeners[].Port" \
  --output text 2>/dev/null || true)

if echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$UPLOADER_LISTENER_PORT"; then
  echo "Uploader listener already exists, skipping."
else
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port "$UPLOADER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$UPLOADER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null
fi

if echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$VIEWER_LISTENER_PORT"; then
  echo "Viewer listener already exists, skipping."
else
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port "$VIEWER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$VIEWER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null
fi

ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" \
  --output text \
  --region "$AWS_REGION")

echo "ALB DNS name: $ALB_DNS_NAME"

echo "== Auto Scaling Groups =="

EXISTING_UPLOADER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$UPLOADER_ASG_NAME" \
  --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text)

if [ "$EXISTING_UPLOADER_ASG" = "None" ] || [ -z "$EXISTING_UPLOADER_ASG" ]; then
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$UPLOADER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$UPLOADER_LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$UPLOADER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$UPLOADER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=uploader-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"
else
  echo "Uploader ASG already exists, skipping."
fi

EXISTING_VIEWER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$VIEWER_ASG_NAME" \
  --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text)

if [ "$EXISTING_VIEWER_ASG" = "None" ] || [ -z "$EXISTING_VIEWER_ASG" ]; then
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$VIEWER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$VIEWER_LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 1 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$VIEWER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$VIEWER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=viewer-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"
else
  echo "Viewer ASG already exists, skipping."
fi

echo "Both Auto Scaling Groups configured."

echo "== Saving stack outputs =="

cat > stack_outputs.env << EOF
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SECURITY_GROUP_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
UPLOADER_TG_ARN=$UPLOADER_TG_ARN
VIEWER_TG_ARN=$VIEWER_TG_ARN
EOF

echo "== Deployment complete =="

echo "ALB DNS name: $ALB_DNS_NAME"
echo "Uploader: http://$ALB_DNS_NAME:$UPLOADER_LISTENER_PORT/"
echo "Viewer: http://$ALB_DNS_NAME:$VIEWER_LISTENER_PORT/"

echo "Allow time for the applications to start and health checks to pass."

echo "Check Uploader health with:"
echo "aws elbv2 describe-target-health --target-group-arn $UPLOADER_TG_ARN --region $AWS_REGION"

echo "Check Viewer health with:"
echo "aws elbv2 describe-target-health --target-group-arn $VIEWER_TG_ARN --region $AWS_REGION"


