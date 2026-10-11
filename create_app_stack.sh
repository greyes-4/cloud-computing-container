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

echo "== Launching instances from templates =="

UPLOADER_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateName=$UPLOADER_LT_NAME,Version=\$Latest" \
  --count 1 \
  --region "$AWS_REGION" \
  --query "Instances[0].InstanceId" \
  --output text)

VIEWER_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateName=$VIEWER_LT_NAME,Version=\$Latest" \
  --count 1 \
  --region "$AWS_REGION" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "$UPLOADER_ID" > uploader_instance_id.txt
echo "$VIEWER_ID" > viewer_instance_id.txt

echo "Waiting for both instances to reach running state..."

aws ec2 wait instance-running \
  --instance-ids "$UPLOADER_ID" "$VIEWER_ID" \
  --region "$AWS_REGION"

echo "== EC2 Instances =="

aws ec2 describe-instances \
  --instance-ids "$UPLOADER_ID" "$VIEWER_ID" \
  --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value|[0],State.Name,PublicIpAddress]" \
  --output table \
  --region "$AWS_REGION"

echo "Instances are running. Allow 60-90 seconds for Node.js installation before testing port 3000."
