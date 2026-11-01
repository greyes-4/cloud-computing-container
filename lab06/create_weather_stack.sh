#!/bin/bash
set -euo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GEMINI_PARAM_ARN="arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${GEMINI_PARAM_NAME}"
DB_PASSWORD_ARN="arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${DB_PASSWORD_PARAM}"

# Create an IAM role and instance profile if needed.
ensure_role_and_profile() {
  local ROLE="$1" PROFILE="$2"

  aws iam create-role \
    --role-name "$ROLE" \
    --assume-role-policy-document file://trust-policy.json \
    >/dev/null 2>&1 || echo "Role $ROLE exists, skipping."

  aws iam create-instance-profile \
    --instance-profile-name "$PROFILE" \
    >/dev/null 2>&1 || echo "Profile $PROFILE exists, skipping."

  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE" \
    --role-name "$ROLE" >/dev/null 2>&1 || true
}

# Create a target group if needed and return its ARN.
ensure_target_group() {
  local NAME="$1" ARN

  ARN=$(aws elbv2 describe-target-groups \
    --names "$NAME" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text 2>/dev/null || true)

  if [ -z "$ARN" ] || [ "$ARN" = "None" ]; then
    ARN=$(aws elbv2 create-target-group \
      --name "$NAME" \
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
      --query "TargetGroups[0].TargetGroupArn" \
      --output text)
  else
    echo "Target group $NAME already exists, skipping." >&2
  fi

  echo "$ARN"
}

build_user_data() {
  local NAME="$1" APP_DIR="$2" EXTRA_ENV="$3" EXTRA_SETUP="${4:-}"
  local APP_JS_B64 PKG_JSON_B64

  APP_JS_B64=$(base64 -w0 "$APP_DIR/app.js")
  PKG_JSON_B64=$(base64 -w0 "$APP_DIR/package.json")

  cat > "user-data-${NAME}.sh" << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
${EXTRA_SETUP}

echo "$APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$PKG_JSON_B64" | base64 -d > /opt/app/package.json

cd /opt/app
npm install --omit=dev

cat > /etc/systemd/system/${NAME}.service << SERVICE
[Unit]
Description=${NAME} app
After=network.target

[Service]
Environment=PORT=3000
Environment=AWS_REGION=$AWS_REGION
${EXTRA_ENV}
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE

chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable ${NAME}.service
systemctl start ${NAME}.service
EOF
}

# Create or update an EC2 launch template.
ensure_launch_template() {
  local LT_NAME="$1" PROFILE="$2" USERDATA_FILE="$3" TAG="$4"

  cat > "lt-data-${TAG}.json" << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": { "Name": "$PROFILE" },
  "UserData": "$(base64 -w0 "$USERDATA_FILE")",
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        { "Key": "Name", "Value": "$TAG" }
      ]
    }
  ]
}
EOF

  if aws ec2 describe-launch-templates \
    --launch-template-names "$LT_NAME" >/dev/null 2>&1; then

    echo "Launch template $LT_NAME exists, creating new version."

    aws ec2 create-launch-template-version \
      --launch-template-name "$LT_NAME" \
      --launch-template-data "file://lt-data-${TAG}.json" \
      >/dev/null
  else
    aws ec2 create-launch-template \
      --launch-template-name "$LT_NAME" \
      --launch-template-data "file://lt-data-${TAG}.json" \
      >/dev/null
  fi
}

# Create an Auto Scaling Group if it does not exist.
ensure_asg() {
  local ASG="$1" LT_NAME="$2" TG_ARN="$3" TAG="$4" EXISTING

  EXISTING=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].AutoScalingGroupName" \
    --output text 2>/dev/null || true)

  if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
    aws autoscaling create-auto-scaling-group \
      --auto-scaling-group-name "$ASG" \
      --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
      --min-size 1 \
      --max-size 1 \
      --desired-capacity 1 \
      --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
      --target-group-arns "$TG_ARN" \
      --health-check-type ELB \
      --health-check-grace-period 120 \
      --tags "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Name,Value=$TAG,PropagateAtLaunch=true"
  else
    echo "Auto Scaling Group $ASG already exists, skipping."
  fi
}
echo "== 1. Create IAM roles and instance profiles =="
ensure_role_and_profile "$WEATHER_ROLE_NAME" "$WEATHER_PROFILE_NAME"
ensure_role_and_profile "$ADVISOR_ROLE_NAME" "$ADVISOR_PROFILE_NAME"

echo "== 2. Grant each role access to its own secret =="
aws iam put-role-policy \
  --role-name "$WEATHER_ROLE_NAME" \
  --policy-name WeatherDbPasswordAccess \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":\"ssm:GetParameter\",
      \"Resource\":\"$DB_PASSWORD_ARN\"
    }]
  }"

aws iam put-role-policy \
  --role-name "$ADVISOR_ROLE_NAME" \
  --policy-name AdvisorGeminiKeyAccess \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":\"ssm:GetParameter\",
      \"Resource\":\"$GEMINI_PARAM_ARN\"
    }]
  }"

echo "== 3. Find default VPC and subnets =="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" --output text)

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" --output text)

echo "VPC: $VPC_ID"
echo "Subnet A: $SUBNET_A"
echo "Subnet B: $SUBNET_B"

echo "== 4. Configure ALB security group =="
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Weather Advisor ALB security group" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
fi

for PORT in "$WEATHER_LISTENER_PORT" "$ADVISOR_LISTENER_PORT"; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp --port "$PORT" \
    --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
done

echo "== 5. Restrict application access to the ALB =="
aws ec2 revoke-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --cidr 0.0.0.0/0 \
  >/dev/null 2>&1 || true

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 \
  --source-group "$ALB_SG_ID" >/dev/null 2>&1 || true

echo "ALB security group: $ALB_SG_ID"

echo "== 6. Create target groups =="
WEATHER_TG_ARN=$(ensure_target_group "$WEATHER_TG_NAME")
ADVISOR_TG_ARN=$(ensure_target_group "$ADVISOR_TG_NAME")

echo "== 7. Create Application Load Balancer =="
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)
fi

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)

echo "ALB DNS: $ALB_DNS"

echo "== 8. Create listeners =="
for SPEC in \
  "$WEATHER_LISTENER_PORT:$WEATHER_TG_ARN" \
  "$ADVISOR_LISTENER_PORT:$ADVISOR_TG_ARN"; do

  PORT="${SPEC%%:*}"
  TG_ARN="${SPEC#*:}"

  EXISTING=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`$PORT\`].ListenerArn | [0]" \
    --output text 2>/dev/null || true)

  if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
    aws elbv2 create-listener \
      --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP \
      --port "$PORT" \
      --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
      >/dev/null
  else
    echo "Listener on port $PORT already exists, skipping."
  fi
done

# Build EC2 user-data for the weather or advisor application.

echo "== 9. Build Weather and Advisor launch templates =="

# Load the database endpoint.
if [ ! -f db_outputs.env ]; then
  echo "ERROR: db_outputs.env is missing."
  exit 1
fi
source db_outputs.env

WEATHER_ENV="Environment=\"NWS_USER_AGENT=(itmo-444-544 weather lab, ${CONTACT_EMAIL})\"
Environment=DB_HOST=${DB_HOST}
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASSWORD_PARAM=${DB_PASSWORD_PARAM}
Environment=CACHE_SECONDS=${CACHE_SECONDS}"

WEATHER_SETUP="dnf install -y postgresql15
curl -sS -o /opt/app/rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"

ADVISOR_ENV="Environment=WEATHER_URL=http://${ALB_DNS}:${WEATHER_LISTENER_PORT}
Environment=GEMINI_KEY_PARAM=${GEMINI_PARAM_NAME}
Environment=GEMINI_MODEL=${GEMINI_MODEL}
Environment=KEY_CACHE_SECONDS=${KEY_CACHE_SECONDS}"

build_user_data weather weather-app "$WEATHER_ENV" "$WEATHER_SETUP"
build_user_data advisor advisor-app "$ADVISOR_ENV"

ensure_launch_template "$WEATHER_LT_NAME" "$WEATHER_PROFILE_NAME" user-data-weather.sh weather-app
ensure_launch_template "$ADVISOR_LT_NAME" "$ADVISOR_PROFILE_NAME" user-data-advisor.sh advisor-app

echo "== 10. Create Auto Scaling Groups =="
ensure_asg "$WEATHER_ASG_NAME" "$WEATHER_LT_NAME" "$WEATHER_TG_ARN" weather-app
ensure_asg "$ADVISOR_ASG_NAME" "$ADVISOR_LT_NAME" "$ADVISOR_TG_ARN" advisor-app

cat > stack_outputs.env << EOF
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SG_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS
WEATHER_TG_ARN=$WEATHER_TG_ARN
ADVISOR_TG_ARN=$ADVISOR_TG_ARN
EOF

echo
echo "Done. ALB DNS name: $ALB_DNS"
echo "Weather service: http://$ALB_DNS:$WEATHER_LISTENER_PORT/weather?zip=60616"
echo "Advisor page: http://$ALB_DNS:$ADVISOR_LISTENER_PORT/"
