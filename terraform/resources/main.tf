# Load environment variables or pass them in via .tfvars
variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default = {
    owner : "del-org"
    team : "session11"
    environment : "dev"
    project : "aws-sso"
    create_by : "Terraform"
    cloud_provider : "aws"
  }
}

# -------------------------------------------------------------------
# Module: Lambda
# -------------------------------------------------------------------
module "lambda_user_sync" {
  source                    = "../modules/lambda"
  lambda_function_name      = "aws-access-${var.environment}"
  lambda_s3_bucket_for_code = "your-lambda-code-bucket"
  lambda_s3_key_for_code    = "code.zip" # or a path to your packaged .zip
  tags                      = var.tags
}

# -------------------------------------------------------------------
# Module: S3
# -------------------------------------------------------------------
module "s3_user_upload" {
  source              = "../modules/s3"
  bucket_name         = "user-upload-bucket-${var.environment}"
  lambda_function_arn = module.lambda_user_sync.lambda_arn
  tags                = var.tags
}
