# DynamoDB table for weather caching and history
resource "aws_dynamodb_table" "weather" {
  name         = "${var.name_prefix}-weather-lookups"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "zip"

  attribute {
    name = "zip"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}

# Create a secure slot for the Gemini API key
resource "aws_ssm_parameter" "gemini" {
  name  = "/${var.name_prefix}/gemini-api-key"
  type  = "SecureString"
  value = "not-set-yet"

  lifecycle {
    ignore_changes = [value]
  }
}
