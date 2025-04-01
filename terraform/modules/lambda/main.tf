variable "lambda_function_name" {
  type        = string
  description = "Name of the Lambda function"
}

variable "lambda_s3_bucket_for_code" {
  type        = string
  description = "S3 bucket containing the Lambda deployment package (if using S3 for code)."
  default     = null
}

variable "lambda_s3_key_for_code" {
  type        = string
  description = "Path to the code zip file in the S3 bucket."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Common tags for resources."
  default     = {}
}

# If you prefer to upload code directly via a .zip file from your local machine, you can define variables for that approach.
variable "lambda_local_package_path" {
  type        = string
  description = "Local path to the Lambda .zip file (used for direct upload)."
  default     = null
}

# Example: The role name you want to use for Lambda
variable "lambda_execution_role_name" {
  type        = string
  description = "Name of the Lambda execution role."
  default     = "lambda_execution_role"
}

provider "aws" {
  # The calling module (in resources/) will pass in the region/credentials
}

# Create an IAM role for the Lambda function
resource "aws_iam_role" "lambda_execution_role" {
  name               = var.lambda_execution_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

# Minimal trust policy for Lambda
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Attach basic execution + logging + S3 read permissions to the Lambda role
resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${var.lambda_execution_role_name}_policy"
  role   = aws_iam_role.lambda_execution_role.id
  policy = data.aws_iam_policy_document.lambda_inline_policy.json
}

data "aws_iam_policy_document" "lambda_inline_policy" {
  statement {
    sid       = "AllowLogging"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid       = "AllowS3Read"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::*"
    ]
  }

  # If your Lambda needs to call Identity Store or SSO, add more permissions here
  # e.g. "identitystore:ListUsers", "identitystore:CreateUser", ...
  # Just ensure you follow the principle of least privilege
  statement {
    sid       = "AllowIdentityStoreAccess"
    actions   = [
      "identitystore:ListUsers",
      "identitystore:CreateUser",
      "identitystore:CreateGroupMembership",
      # ...
    ]
    resources = ["*"]
  }
}

# Decide whether to use S3 or direct .zip file for the Lambda code
resource "aws_lambda_function" "this" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  tags          = var.tags

  # If using S3:
  #   publish = true
  #   s3_bucket = var.lambda_s3_bucket_for_code
  #   s3_key    = var.lambda_s3_key_for_code

  # If uploading code directly:
  #   filename = var.lambda_local_package_path

  # For illustration, we show S3-based deployment
  s3_bucket = var.lambda_s3_bucket_for_code
  s3_key    = var.lambda_s3_key_for_code
  publish   = true
}

output "lambda_arn" {
  description = "ARN of the created Lambda function"
  value       = aws_lambda_function.this.arn
}
