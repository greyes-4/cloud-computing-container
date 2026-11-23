#!/bin/bash
set -e

echo "== Deleting SNS topic =="
aws sns delete-topic \
  --topic-arn arn:aws:sns:us-east-2:284901686080:resume-mailer-greyes \
  --region us-east-2 \
  --no-cli-pager

echo "== Deleting SSM parameter =="
aws ssm delete-parameter \
  --name /itmo-444/gemini-api-key \
  --region us-east-2 \
  --no-cli-pager

echo "Project cleanup complete."
