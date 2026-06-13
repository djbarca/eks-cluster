variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster."
  type        = string
}

variable "history_server_bucket" {
  description = "Name of the S3 bucket holding Spark job history. Required when enable_history_server = true."
  type        = string
  default     = ""
}

variable "history_server_bucket_arn" {
  description = "ARN of the S3 bucket holding Spark job history. Required when enable_history_server = true."
  type        = string
  default     = ""
}

variable "spark_namespace" {
  description = "Kubernetes namespace for Spark job submissions."
  type        = string
  default     = "spark"
}

variable "spark_namespace_cpu_limit" {
  description = "ResourceQuota CPU limit for the Spark namespace."
  type        = string
  default     = "500"
}

variable "spark_namespace_memory_limit" {
  description = "ResourceQuota memory limit for the Spark namespace."
  type        = string
  default     = "2000Gi"
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}

variable "enable_history_server" {
  description = "Deploy the Spark History Server (requires a pre-existing S3 bucket passed via history_server_bucket)."
  type        = bool
  default     = true
}

variable "enable_yunikorn" {
  description = "Install YuniKorn gang scheduler."
  type        = bool
  default     = true
}

variable "job_data_bucket_arns" {
  description = "ARNs of S3 buckets that Spark jobs can read/write. Used to scope an IAM role for the `spark` service account via Pod Identity. Empty list = no job IAM role created."
  type        = list(string)
  default     = []
}
