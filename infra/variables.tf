variable "region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" { type = string }      # Your AWS account ID
variable "repo_owner" { type = string }      # e.g., "WebForxTech" (GitHub org or username)
variable "repo_name" { type = string }       # e.g., "students-onboarding"
variable "csv_bucket_name" { type = string } # globally-unique, e.g., "wf-students-csv-<random>"
variable "email_sender" { type = string }    # Verified SES sender, e.g., "no-reply@yourdomain.com"
variable "slack_webhook_ssm_parameter" {
  type    = string
  default = "/student/slack_webhook"
}


# IAM Identity Center / SSO inputs (find these once and keep)
variable "sso_instance_arn" { type = string }  # arn:aws:sso:::instance/ssoins-...
variable "identity_store_id" { type = string } # d-xxxxxxxxxx
variable "target_account_id" { type = string } # same or another account ID

# Optional: create SES template (requires verified domain already)
variable "create_ses_template" {
  type    = bool
  default = true
}

