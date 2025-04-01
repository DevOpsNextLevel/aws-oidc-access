terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket"  # same bucket created above
    key            = "awsssouserautomation/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock"               # same table created above
  }
}
