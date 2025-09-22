locals {
  csv_prefix  = "students/"
  dlq_name    = "students-csv-dlq"
  queue_name  = "students-csv-queue"
  project_tag = "students-onboarding"
}

# ---------------------------------------------------------------------
# GitHub OIDC for Actions -> AWS -- If creating a new Identity provider
# ---------------------------------------------------------------------
#resource "aws_iam_openid_connect_provider" "github" {
#  url             = "https://token.actions.githubusercontent.com"
#  client_id_list  = ["sts.amazonaws.com"]
#  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
#}

#---------------------
# If there is already and existing Identity provider in the AWS account
#---------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.repo_owner}/${var.repo_name}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name               = "github-ci-students"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
  tags               = { Project = local.project_tag }
}

data "aws_iam_policy_document" "github_ci_policy" {
  statement {
    actions   = ["s3:PutObject", "s3:PutObjectAcl"]
    resources = ["arn:aws:s3:::${var.csv_bucket_name}/${local.csv_prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.csv_bucket_name}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.csv_prefix}*"]
    }
  }
}

resource "aws_iam_role_policy" "github_ci_inline" {
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_policy.json
}

# ---------------------------
# S3 bucket for CSV ingest
# ---------------------------
resource "aws_s3_bucket" "csv" {
  bucket = var.csv_bucket_name
  tags   = { Project = local.project_tag, Owner = "Web Forx Technology Limited" }
}

resource "aws_s3_bucket_versioning" "csv_ver" {
  bucket = aws_s3_bucket.csv.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "csv_enc" {
  bucket = aws_s3_bucket.csv.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# ---------------------------
# SQS (with DLQ) for durability/retries
# ---------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = local.dlq_name
  message_retention_seconds = 1209600 # 14 days
  tags                      = { Project = local.project_tag }
}

resource "aws_sqs_queue" "queue" {
  name                       = local.queue_name
  visibility_timeout_seconds = 180
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
  tags = { Project = local.project_tag }
}

# Allow S3 to send notifications to SQS
data "aws_iam_policy_document" "sqs_from_s3" {
  statement {
    sid     = "AllowS3Send"
    actions = ["SQS:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.queue.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.csv.arn]
    }
  }
}
resource "aws_sqs_queue_policy" "queue_policy" {
  queue_url = aws_sqs_queue.queue.id
  policy    = data.aws_iam_policy_document.sqs_from_s3.json
}

# S3 -> SQS event notification (ObjectCreated under students/ prefix)
resource "aws_s3_bucket_notification" "csv_to_sqs" {
  bucket = aws_s3_bucket.csv.id
  queue {
    queue_arn     = aws_sqs_queue.queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = local.csv_prefix
  }
  depends_on = [aws_sqs_queue_policy.queue_policy]
}

# ---------------------------
# DynamoDB table for idempotency
# ---------------------------
resource "aws_dynamodb_table" "user_provisioning" {
  name         = "user_provisioning"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "username"
  attribute {
    name = "username"
    type = "S"
  }

  tags = { Project = local.project_tag }
}

# ---------------------------
# IAM Identity Center permission set (CustomPolicy)
# ---------------------------
# Create the permission set
resource "aws_ssoadmin_permission_set" "custom" {
  name         = "CustomPolicy"
  instance_arn = var.sso_instance_arn
  session_duration = "PT4H"
  description  = "Custom inline policy for student access"
}

# Attach the inline JSON policy
resource "aws_ssoadmin_permission_set_inline_policy" "custom" {
  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.custom.arn
  inline_policy      = file("${path.module}/policies/custom_policy.json")
}

# ---------------------------
# Lambda (user provisioning)
# ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda-user-provisioner"
  output_path = "${path.module}/lambda-user-provisioner.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "lambda-user-provisioner-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = local.project_tag }
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["arn:aws:s3:::${var.csv_bucket_name}/${local.csv_prefix}*"]
  }
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.queue.arn]
  }
  statement {
    actions = [
      "identitystore:ListUsers",
      "identitystore:CreateUser",
      "identitystore:ListGroups",
      "identitystore:CreateGroupMembership"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "sso-admin:CreateAccountAssignment",
      "sso-admin:DescribeAccountAssignmentCreationStatus",
      "sso-admin:DescribePermissionSet",
      "sso-admin:ProvisionPermissionSet",
      "sso-admin:ListPermissionSets"
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.user_provisioning.arn]
  }
  # Optional: read Slack webhook from SSM
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.slack_webhook_ssm_parameter}"]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_lambda_function" "provisioner" {
  function_name = "students-user-provisioner"
  role          = aws_iam_role.lambda_role.arn
  architectures = ["x86_64"]
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 512
  filename      = data.archive_file.lambda_zip.output_path
  environment {
    variables = {
      IDENTITY_STORE_ID   = var.identity_store_id
      INSTANCE_ARN        = var.sso_instance_arn
      PERMISSION_SET_ARN  = aws_ssoadmin_permission_set.custom.arn
      TARGET_ACCOUNT_ID   = var.target_account_id
      SES_SENDER          = var.email_sender
      SLACK_WEBHOOK_PARAM = var.slack_webhook_ssm_parameter
      DDB_TABLE           = aws_dynamodb_table.user_provisioning.name
      CSV_BUCKET          = var.csv_bucket_name
      CSV_PREFIX          = local.csv_prefix
      ACCESS_PORTAL_URL   = "https://<your-access-portal>.awsapps.com/start"
      STUDENT_GROUP_NAME  = "Students" # optional group in Identity Center
    }
  }
  tags = { Project = local.project_tag }
}

# Event source: SQS -> Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn                   = aws_sqs_queue.queue.arn
  function_name                      = aws_lambda_function.provisioner.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 10
  enabled                            = true
}

# ---------------------------
# SES Template (optional)
# ---------------------------
resource "aws_ses_template" "student_welcome" {
  count   = var.create_ses_template ? 1 : 0
  name    = "StudentWelcome"
  subject = "Your AWS Lab Access"
  html    = <<EOF
  <h3>Welcome to the AWS Lab</h3>
  <p>Hello {{first_name}},</p>
  <p>Your user <b>{{username}}</b> has been created.</p>
  <p>Sign in here: <a href="{{portal_url}}">{{portal_url}}</a></p>
  <p>First-time steps:</p>
  <ol>
    <li>Verify your email / set password if prompted</li>
    <li>Enroll MFA (Authenticator app)</li>
    <li>Choose the account <b>{{account_id}}</b> and role <b>CustomPolicy</b></li>
  </ol>
  <p>Thanks,<br/>Web Forx Technology Limited</p>
  EOF
  text    = <<EOF
  Welcome to the AWS Lab

  Hello {{first_name}},

  Your user {{username}} has been created.
  Sign in: {{portal_url}}

  First-time steps:
  1) Verify email / set password if prompted
  2) Enroll MFA (Authenticator app)
  3) Choose account {{account_id}} and role CustomPolicy

  Thanks,
  Web Forx Technology Limited
  EOF
}
