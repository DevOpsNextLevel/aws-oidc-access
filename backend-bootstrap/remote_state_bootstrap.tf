provider "aws" {
  region = "us-east-1"
  allowed_account_ids = ["account_id"]
}

resource "aws_s3_bucket" "tf_state_bucket" {
  bucket = "aws-sso-access-s11"  # Change this to a globally unique name
  acl    = "private"

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

  tags = {
    Owner         = "del-org"
    environment = "dev"
    project = "aws-sso"
  }
}

resource "aws_dynamodb_table" "tf_state_lock" {
  name         = "aws-sso-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Owner         = "del-org"
    Environment   = "dev"
    Project       = "aws-sso"
  }
}
