# AWS SSO User Automation

This project automates the process of provisioning federated access for students in AWS IAM Identity Center (formerly AWS SSO) by processing a CSV file stored in a GitHub repository. When changes are merged into the main branch, a GitHub Actions workflow uploads the CSV to an S3 bucket, triggering a Lambda function that creates new users (while skipping duplicates) and sends a Slack notification with a summary of the operation.

## Table of Contents

- [AWS SSO User Automation](#aws-sso-user-automation)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Architecture](#architecture)
  - [Setup](#setup)
    - [AWS Configuration](#aws-configuration)
    - [Add slack\_url to paramter store](#add-slack_url-to-paramter-store)
  - [GitHub Actions Workflow](#github-actions-workflow)
    - [Branch Protection \& PR Workflow](#branch-protection--pr-workflow)
  - [How It Works](#how-it-works)
    - [CSV Upload:](#csv-upload)
    - [Lambda Trigger:](#lambda-trigger)
    - [User Processing:](#user-processing)
    - [Notifications:](#notifications)
    - [AWS Invitation:](#aws-invitation)
    - [Usage Instructions for Students](#usage-instructions-for-students)
    - [Create a New Branch:](#create-a-new-branch)
    - [Update the CSV File:](#update-the-csv-file)
    - [Commit Your Changes:](#commit-your-changes)
    - [Push Your Branch:](#push-your-branch)
    - [On GitHub, create a PR from your branch into main.](#on-github-create-a-pr-from-your-branch-into-main)
    - [After PR Merge:](#after-pr-merge)
  - [AWS Account Setup:](#aws-account-setup)
    - [Follow the instructions to:](#follow-the-instructions-to)
  - [Contributing](#contributing)
  - [Issues:](#issues)
  - [License](#license)

## Overview

This project automates student onboarding into AWS IAM Identity Center. It processes a CSV file (`data/students.csv`) that contains student details (FirstName, LastName, Username, Email) and creates their federated access in AWS. Duplicate entries are skipped. Upon processing, a Slack notification is sent to summarize the created and skipped users. The solution leverages:

- **GitHub Actions** – to upload the CSV file to an S3 bucket upon changes.
- **Amazon S3** – to trigger the Lambda function when the CSV file is updated.
- **AWS Lambda** – to read and process the CSV, create users, and add them to a permission group.
- **AWS Identity Store** – to manage users and groups in AWS IAM Identity Center.
- **Slack** – for notifications.

## Architecture

```mermaid
graph TD;
    A[GitHub Repo (data/students.csv)]
    B[GitHub Actions Workflow]
    C[Amazon S3 Bucket]
    D[AWS Lambda Function]
    E[AWS Identity Center (Identity Store)]
    F[Slack Notifications]

    A --> B
    B --> C
    C --> D
    D --> E
    D --> F
```

- GitHub Repo: Contains the students.csv file.

- GitHub Actions: Watches for changes to data/students.csv on the main branch, then uploads the CSV to an S3 bucket.

- Amazon S3: Triggers the Lambda function on file upload.

- AWS Lambda: Reads the CSV, checks for existing users, creates new users in Identity Center, and adds them to a group.

- Slack: Sends notifications summarizing the process.

 ** The mental model (one minute)**
-  SNS = megaphone. You publish one message; lots of subscribers can get it (SQS queues, Lambdas, HTTPS endpoints, email/SMS, etc.). Decouples senders from receivers.

-  SQS = mailbox. A durable queue that holds messages for workers to pull and process at their pace.

-  DLQ (Dead-Letter Queue) = the “bad mail” bin. If a worker tries a message several times and still can’t process it, the message is moved to a separate queue so you can inspect/replay it safely.

-  SES = the post office. Fully managed email: send (outbound), receive (inbound), measure deliverability, handle bounces/complaints.

We’ll use SNS to broadcast an event, SQS (with a DLQ) to buffer/process, and SES to email someone when work is done—or to notify you if it fails.

**1) Amazon SES (Simple Email Service) — what matters**
**Core ideas**

-  **Sandbox vs Production**

  -  New accounts start in sandbox: you can only send to verified identities (emails/domains). Request production access when ready.

- Identities: Verify a domain (best) or individual email (quick test). Domain verification gives you DKIM and SPF.

-  Send via API or SMTP. For apps/Lambda, use the API (boto3 sesv2).

-  Config Sets: add rules (event destinations, dedicated IP pool, tracking).

-  Event Destinations: stream SES events (delivered/opened/bounce/complaint) to SNS / Kinesis / CloudWatch.

-  Suppression list: SES avoids sending to repeatedly bouncing addresses.

-  Deliverability: set up SPF, DKIM, and ideally DMARC on your domain. Warm up sending gradually if using dedicated IPs.

**Minimal DNS checklist (custom domain)**

-  SPF (TXT): v=spf1 include:amazonses.com ~all

-  DKIM (CNAMEs): 3 records SES gives you after domain verification.

-  DMARC (TXT): v=DMARC1; p=quarantine; rua=mailto:dmarc@yourdomain.com (start with “none” to monitor, then tighten).

**Common patterns with SES**

-  App emails (password resets, receipts): app → SES API.

-  Ops alerts: Lambda or Step Functions → SES.

-  Inbound mail processing: SES Receipt Rules → S3/Lambda for parsing tickets, approvals, etc.

-  Bounce/complaint loops: SES → SNS → SQS/Lambda to auto-suppress bad addresses in your DB.

**2) Amazon SNS — publish/subscribe**
**Core ideas**

-  Standard topics (best for most): at-least-once delivery, high throughput, best-effort order.

-  FIFO topics: strict ordering + exactly-once to FIFO SQS; lower throughput; needs MessageGroupId.

-  Subscriptions: SQS, Lambda, HTTP/S, email, SMS, mobile push, etc.

-  Message filtering: subscribers get only messages that match attributes (e.g., {"event":"user.signup"}).

-  Security: topic policies for who can publish/subscribe, KMS encryption, VPC endpoints for private access.

-  Retries / DLQ:

    -  To SQS: SQS handles retries + DLQ.

    -  To HTTP/S or Lambda: configure SNS redrive policy (DLQ to SQS) plus delivery retry policy.

**3) Dead-Letter Queues (DLQs) — keep bad messages from poisoning the queue**
**The essentials**

-  Where: Typically you set DLQ on SQS queues (via redrive_policy with maxReceiveCount).

-  Why: Prevents infinite retry loops; isolates bad payloads.

-  Monitoring: Alarm on ApproximateNumberOfMessagesVisible in the DLQ > 0.

-  Reprocessing: “Redrive” messages: move from DLQ back to source for another attempt (after fixing code/config).

-  Lambda + SQS: Lambda reading SQS also respects the SQS queue’s DLQ (since eventually the message lands there).

**4) When to use what (quick guidance)**

-  Only need to send email? SES alone.

-  Fan-out to many systems (email + Slack + DB worker)? SNS in front, with multiple subscribers (SQS worker, Lambda emailer, webhook).

-  Unreliable downstream / spikes? Put SQS between SNS and your worker. Add a DLQ on the SQS.

-  Strict ordering / exactly-once? SNS FIFO → SQS FIFO → single consumer group.

**5) Demo: SNS → SQS (+DLQ) → Lambda worker → SES email**

**What you’ll deploy:**

  1.  SNS topic demo-events

  2.  SQS queue demo-worker-queue (with DLQ demo-dlq)

  3.  Subscription: SNS → SQS (with optional message filter)

  4.  Lambda demo-emailer that:

    -  is triggered by SQS,

    -  sends an email via SES with details from the message.

  5.  CloudWatch Alarm on DLQ > 0 (so you don’t miss failures).

|>⚠️ SES Sandbox: use verified sender and recipient emails. In production, only sender needs to be set up (plus DKIM/SPF/DMARC).

A) Terraform (copy-paste starter)

Create `main.tf` in a fresh folder, run `terraform init` && `terraform apply`.
```
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ses_sender" {
  description = "Verified SES sender email (or domain identity)."
  type        = string
}

variable "ses_recipient" {
  description = "Verified recipient (if in SES sandbox)."
  type        = string
}

# ---------- SNS ----------
resource "aws_sns_topic" "demo" {
  name              = "demo-events"
  kms_master_key_id = "alias/aws/sns"
}

# ---------- SQS + DLQ ----------
resource "aws_sqs_queue" "dlq" {
  name                       = "demo-dlq"
  message_retention_seconds  = 1209600  # 14 days
  sqs_managed_sse_enabled    = true
}

resource "aws_sqs_queue" "worker" {
  name                      = "demo-worker-queue"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
  sqs_managed_sse_enabled = true
}

# Allow SNS to send to SQS
data "aws_iam_policy_document" "sqs_policy" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.worker.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.demo.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "worker" {
  queue_url = aws_sqs_queue.worker.id
  policy    = data.aws_iam_policy_document.sqs_policy.json
}

# Subscribe SQS to SNS (optional filter example included but commented)
resource "aws_sns_topic_subscription" "sub" {
  topic_arn = aws_sns_topic.demo.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.worker.arn

  # Uncomment to filter only specific events:
  # filter_policy = jsonencode({
  #   event = ["user.signup"]
  # })
}

# ---------- Lambda role ----------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "demo-emailer-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Permissions: read from SQS, send via SES, log to CW
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid = "SQSReceive"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility"
    ]
    resources = [aws_sqs_queue.worker.arn]
  }

  statement {
    sid = "SESSend"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]
    resources = ["*"] # tighten to identity ARN if desired
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "demo-emailer-policy"
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ---------- Lambda function ----------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "emailer" {
  function_name = "demo-emailer"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "handler.run"
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = 30
  environment {
    variables = {
      SES_SENDER    = var.ses_sender
      SES_RECIPIENT = var.ses_recipient
    }
  }
}

# Event source: SQS -> Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn  = aws_sqs_queue.worker.arn
  function_name     = aws_lambda_function.emailer.arn
  batch_size        = 5
  maximum_batching_window_in_seconds = 5
}

# ---------- DLQ alarm ----------
resource "aws_cloudwatch_metric_alarm" "dlq_alarm" {
  alarm_name          = "demo-dlq-has-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
  alarm_description = "DLQ contains messages; investigate and redrive."
}
```

Create `lambda/handler.py`:
```
import json, os, boto3, logging
log = logging.getLogger()
log.setLevel(logging.INFO)

ses = boto3.client("ses")  # or sesv2 if you prefer
SENDER = os.environ["SES_SENDER"]
RECIPIENT = os.environ["SES_RECIPIENT"]

def send_email(subject, body):
    ses.send_email(
        Source=SENDER,
        Destination={"ToAddresses": [RECIPIENT]},
        Message={
            "Subject": {"Data": subject},
            "Body": {"Text": {"Data": body}}
        }
    )

def run(event, context):
    # SQS batch
    for record in event["Records"]:
        msg_id = record["messageId"]
        body   = record["body"]
        attrs  = record.get("messageAttributes", {})

        # Simulate failure if asked (to test DLQ)
        if attrs.get("force_fail", {}).get("stringValue") == "true":
            log.error(f"Forcing failure for {msg_id}")
            raise RuntimeError("Forced failure to demo DLQ")

        log.info(f"Processing message {msg_id}: {body}")
        subject = f"Demo processed: {msg_id}"
        send_email(subject, f"Payload:\n{body}")

    return {"ok": True}
```
Create `variables.tf` (optional):
```
variable "region"       { type = string }
variable "ses_sender"   { type = string }
variable "ses_recipient"{ type = string }
```
Create `terraform.tfvars`:
```
region       = "us-east-1"
ses_sender   = "verified-sender@yourdomain.com"
ses_recipient= "verified-recipient@yourdomain.com"
```

Deploy:
`terraform init`
`terraform apply`

B) Test the flow
1) Publish a normal message (should email you)
```
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn,':demo-events')].TopicArn | [0]" --output text)

aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"orderId":123,"note":"hello world"}' \
  --message-attributes '{"event":{"DataType":"String","StringValue":"test"}}'
```

What happens:

  -  SNS receives the message → pushes to SQS.

  -  Lambda is triggered by SQS → sends SES email to ses_recipient.

Check:

  -  CloudWatch Logs for demo-emailer

  -  Email inbox for the message

**2) Force a failure (to see the DLQ get messages)**
```
aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --message '{"orderId":999,"note":"force fail"}' \
  --message-attributes '{"force_fail":{"DataType":"String","StringValue":"true"}}'
```

What happens:

  -  Lambda raises an exception → message is returned to SQS.

  -  After 5 receives (maxReceiveCount), SQS moves it to demo-dlq.

Check the DLQ:
`DLQ_URL=$(aws sqs get-queue-url --queue-name demo-dlq --query QueueUrl --output text)
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 10 --wait-time-seconds 1
`
You should see the failed payload. Your CloudWatch alarm will also trip (DLQ > 0).

**3) Redrive (replay) after fixing code/config**

Manually move messages back to the worker queue:
```
WORKER_URL=$(aws sqs get-queue-url --queue-name demo-worker-queue --query QueueUrl --output text)

# Pull messages from DLQ and send back to worker:
for i in {1..10}; do
  MSGS=$(aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 10 --wait-time-seconds 1 --message-attribute-names All --attribute-names All)
  echo "$MSGS" | jq -r '.Messages[]? | @base64' | while read -r m; do
    BODY=$(echo "$m" | base64 --decode | jq -r .Body)
    ATTR=$(echo "$m" | base64 --decode | jq -r '.MessageAttributes // {}')
    # Re-publish to worker queue (preserving body; attributes omitted for brevity)
    aws sqs send-message --queue-url "$WORKER_URL" --message-body "$BODY"
    RECEIPT=$(echo "$m" | base64 --decode | jq -r .ReceiptHandle)
    aws sqs delete-message --queue-url "$DLQ_URL" --receipt-handle "$RECEIPT"
  done
done
```

**6) Production tips & gotchas (DevOps-y, but simple)**

-  **SES deliverability basics**

  -  Verify domain + enable DKIM; add SPF; start DMARC with policy none then tighten to quarantine/reject.

  -  Avoid sending to users who bounced/complained; wire SES events → SNS → your DB suppression.

  -  Warm up send volume; don’t blast from zero to 100k/day.

**SNS fan-out**

  -  Use message attributes + filter policies so each subscriber only gets what it needs.

  -  For cross-account, allow sns:Subscribe / sns:Publish in the topic policy.

  - Encrypt topics with KMS, and use VPC endpoints for private access from subnets.

-  **SQS tuning**
  -  Visibility timeout must be > your max processing time.

  -  Pick batch size (Lambda) thoughtfully (e.g., 5–10) for throughput vs failure blast radius.

  -  Always add a DLQ with sensible maxReceiveCount (3–10 typically).

-  **Observability**

  -  CloudWatch metrics on: SQS backlog, DLQ count, Lambda errors/throttles, SES bounce/complaint rates.

  -  Add alarms to page you before customers do.

-  **Security**

Principle of least privilege IAM; KMS for SNS/SQS; VPC endpoints for private comms; no public HTTP endpoints unless you must.

-  **Costs (rough order)**

  -  SNS/SQS/Lambda are pennies for small volumes.

  -  SES is ~$0.10 per 1k emails (plus data charges for attachments); free if sending from EC2 for a decent chunk.

  -  Biggest cost levers: email volume + attachment size + large queue backlogs.

**7) Variations you’ll likely need someday**

  -  FIFO ordering: Use SNS FIFO + SQS FIFO + Lambda (needs MessageGroupId).

  -  Inbound email bots: SES → S3 → Lambda (parse MIME) → SNS/SQS for downstream.

  -  Transactional templates: store templates in SES; send via sesv2 with template data.

**8) Cleanup**
``terraform destroy``


***(If SES domain identity/DNS records were created outside TF, remove those separately. If you requested prod access, that’s an account-level setting—keep it.)***

## Setup
**Prerequisites**
* AWS account with IAM Identity Center configured.

* An S3 bucket (e.g., sso-user-creation-s3) to store the CSV.

* A Slack workspace and an Incoming Webhook URL.

* GitHub repository with the project code.

* AWS IAM role for Lambda with permissions:

`identitystore:ListUsers`

`identitystore:CreateUser`

`identitystore:CreateGroupMembership`

`s3:GetObject`

**CloudWatch logging permissions.**

### AWS Configuration
* - Create/Update IAM Role for Lambda: Attach a policy that allows:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "identitystore:ListUsers",
        "identitystore:CreateUser",
        "identitystore:CreateGroupMembership"
      ],
      "Resource": "*"
    }
  ]
}
```

### Add slack_url to paramter store
```
aws ssm put-parameter \
  --name "/students/slack_webhook" \
  --type "SecureString" \
  --value "<Your_slack_url>"
```


*Note: You can scope down the resources later.*

- Set Up Lambda Function:

- Deploy the provided lambda_function.py code.

- Set the environment variable SLACK_WEBHOOK_URL with your Slack webhook URL.

Configure your Lambda to be triggered by the S3 event (on ObjectCreated:Put for students.csv).

## GitHub Actions Workflow
Create the file .github/workflows/upload-to-s3.yml with the following content:
name: Upload to S3 on PR Merge

```
on:
  push:
    branches:
      - main
    paths:
      - 'data/students.csv'

jobs:
  upload-to-s3:
    environment: AWS-Credentials   # Ensure this matches your GitHub environment that holds your AWS secrets
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Upload students.csv to S3
        run: |
          aws s3 cp data/students.csv s3://sso-user-creation-s3/employee.csv
```

export AWS_ACCESS_KEY_ID="your_access_key_id"
export AWS_SECRET_ACCESS_KEY="your_secret_access_key"
export AWS_DEFAULT_REGION="us-east-1"

>We will be setting up OIDC credentials with Github but if thats not the route you choise to follow then:
*Make sure to store AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY as GitHub Secrets (or in an Environment like AWS-Credentials).*


### Branch Protection & PR Workflow
Go to your GitHub repository Settings > Branches.

1.  Add a branch protection rule for main:

2.  Require pull requests before merging.

3.  Require approvals (e.g., at least one reviewer).

4.  Optionally, require linear history and disallow self-approvals.

## How It Works
Updating the CSV:
When a change is made to data/students.csv (via a pull request merge into main), the GitHub Actions workflow triggers.

### CSV Upload:
The workflow uploads the CSV to the S3 bucket.

### Lambda Trigger:
S3 sends an event to the Lambda function.

### User Processing:
The Lambda function:

Reads the CSV.

Checks each row for an existing user by filtering on UserName.

Creates new users if they don’t exist.

Adds new users to the specified group.

**Skips duplicate users.**

### Notifications:
Slack is notified with a summary of the created and skipped users.

### AWS Invitation:
Once your user is created, AWS sends an invitation email. Follow the email instructions to set up your initial password and Multi-Factor Authentication (MFA).

### Usage Instructions for Students
How to Request Your AWS Access
Clone the Repository:

``git clone git@git.edusuc.net:WEBFORX/AWSSSOUserAutomation.git``

``cd sso-user-automation``

### Create a New Branch:
``git checkout -b feature/UserName``

### Update the CSV File:

Open data/students.csv in your text editor.

Add your details as a new row:
```
FirstName,LastName,Username,Email
YourFirstName,YourLastName,desiredUsername,your.email@example.com
Save your changes.
```

### Commit Your Changes:

``git add data/employee.csv``
``git commit -m "Add new employee: [Your UserName]"``

### Push Your Branch:
``git push origin add-your-username>``

Create a Pull Request (PR):

### On GitHub, create a PR from your branch into main.

- Add a description, then submit the PR.

*Note: Your PR must be reviewed and approved (by a designated reviewer) before merging.*

### After PR Merge:

Once the PR is merged into main, the GitHub Actions workflow will trigger.

The updated CSV is uploaded to S3, and the Lambda function processes the file.

AWS will send you an invitation email to join the AWS Identity Center.

## AWS Account Setup:

Check your email for the AWS invitation.

### Follow the instructions to:

- Set your initial password.

- Set up Multi-Factor Authentication (MFA) using an authenticator app.

After completing these steps, you can log in and access your AWS environment.

## Contributing
Pull Requests:
All changes should be submitted via pull requests. Please ensure that you follow the branch protection rules and have your changes reviewed before merging.

## Issues:
Feel free to open issues if you encounter any problems or have suggestions for improvement.

## License
This project is licensed under the MIT License.

---

This README provides a comprehensive overview of the project, its architecture, setup, and detailed usage instructions for both administrators and students. Feel free to modify or extend it as needed. Enjoy automating your AWS user provisioning!
***Test change
