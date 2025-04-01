variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket."
}

variable "lambda_function_arn" {
  type        = string
  description = "ARN of the Lambda function to trigger."
}

variable "tags" {
  type        = map(string)
  description = "Common tags for resources."
  default     = {}
}

provider "aws" {
  # The calling module will pass in region/credentials
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
  tags   = var.tags

  # Recommended: enable versioning and server-side encryption
  versioning {
    enabled = true
  }
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

# Create the Bucket -> Lambda notification
resource "aws_s3_bucket_notification" "this" {
  bucket = aws_s3_bucket.this.id

  lambda_function {
    lambda_function_arn = var.lambda_function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "data/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_function_permission.allow_s3]
}

# Give S3 permission to invoke the Lambda
resource "aws_lambda_function_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_arn
  principal     = "s3.amazonaws.com"

  # The source ARN must match the bucket ARN
  source_arn = aws_s3_bucket.this.arn
}

output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.this.bucket
}
