output "spark_history_server_role_arn" {
  description = "ARN of the Spark History Server IAM role (null if enable_history_server = false)."
  value       = try(aws_iam_role.spark_history_server[0].arn, null)
}

output "spark_namespace" {
  description = "Name of the Spark Kubernetes namespace."
  value       = var.spark_namespace
}

output "spark_job_role_arn" {
  description = "ARN of the Spark job IAM role (Pod Identity for the `spark` SA). Null if job_data_bucket_arns is empty."
  value       = try(aws_iam_role.spark_job[0].arn, null)
}
