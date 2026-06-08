output "lbc_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role (null if enable_lbc = false)."
  value       = try(aws_iam_role.lbc[0].arn, null)
}

output "fluentbit_role_arn" {
  description = "ARN of the Fluent Bit IAM role (null if enable_fluentbit = false)."
  value       = try(aws_iam_role.fluentbit[0].arn, null)
}
