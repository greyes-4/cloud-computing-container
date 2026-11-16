# Trust policy allowing EC2 to assume IAM roles
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Separate IAM role for each application tier
resource "aws_iam_role" "tier" {
  for_each = local.tiers

  name               = "${var.name_prefix}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Instance profiles attach roles to EC2 instances
resource "aws_iam_instance_profile" "tier" {
  for_each = local.tiers

  name = "${var.name_prefix}-${each.key}-profile"
  role = aws_iam_role.tier[each.key].name
}

# Weather service permissions
data "aws_iam_policy_document" "weather" {
  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Scan"
    ]
    resources = [aws_dynamodb_table.weather.arn]
  }
}

# Advisor service permissions
data "aws_iam_policy_document" "advisor" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.gemini.arn]
  }
}

# Attach DynamoDB permissions to Weather
resource "aws_iam_role_policy" "weather" {
  name   = "${var.name_prefix}-weather-policy"
  role   = aws_iam_role.tier["weather"].id
  policy = data.aws_iam_policy_document.weather.json
}

# Attach Parameter Store permissions to Advisor
resource "aws_iam_role_policy" "advisor" {
  name   = "${var.name_prefix}-advisor-policy"
  role   = aws_iam_role.tier["advisor"].id
  policy = data.aws_iam_policy_document.advisor.json
}
