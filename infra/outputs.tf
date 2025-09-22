output "csv_bucket" { value = aws_s3_bucket.csv.bucket }
output "sqs_queue" { value = aws_sqs_queue.queue.name }
output "lambda_arn" { value = aws_lambda_function.provisioner.arn }
output "permission_set_arn" { value = aws_ssoadmin_permission_set.custom.arn }
output "github_oidc_role_arn" { value = aws_iam_role.github_ci.arn }
