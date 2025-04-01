# AWS SSO User Automation

This project automates the process of provisioning federated access for students in AWS IAM Identity Center (formerly AWS SSO) by processing a CSV file stored in a GitHub repository. When changes are merged into the main branch, a GitHub Actions workflow uploads the CSV to an S3 bucket, triggering a Lambda function that creates new users (while skipping duplicates) and sends a Slack notification with a summary of the operation.

## Table of Contents

- [AWS SSO User Automation](#aws-sso-user-automation)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Architecture](#architecture)
  - [Setup](#setup)
    - [AWS Configuration](#aws-configuration)
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

*Note: Make sure to store AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY as GitHub Secrets (or in an Environment like AWS-Credentials).*

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
