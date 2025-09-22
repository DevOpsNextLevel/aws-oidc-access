terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }

  #  backend "s3" {} # (optional) fill if you want remote state
}

provider "aws" {
  region = var.region
  # (Optional safety) allowed_account_ids = [var.account_id]
}
