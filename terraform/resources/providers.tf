terraform {
  required_version = ">= 1.10.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                  = var.aws_region
  allowed_account_ids     = ["774305617666"]
  # By default, the provider will look for AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment
  # or you can specify them directly:
  # access_key = var.aws_access_key
  # secret_key = var.aws_secret_key
}
