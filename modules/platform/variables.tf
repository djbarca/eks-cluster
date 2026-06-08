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

variable "vpc_id" {
  description = "VPC ID — used by the AWS Load Balancer Controller for subnet discovery."
  type        = string
}

variable "aws_region" {
  description = "AWS region for Fluent Bit CloudWatch target."
  type        = string
}

variable "grafana_storage_size" {
  description = "Grafana PVC size. Empty string = ephemeral (no PVC). E.g. \"20Gi\" enables an EBS-backed PVC."
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "cloudwatch_log_group_prefix" {
  description = "CloudWatch log group prefix. Full path = <prefix>/<cluster_name>."
  type        = string
  default     = "/eks"
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}

###############################################################################
# Component feature flags
###############################################################################

variable "enable_lbc" {
  description = "Install the AWS Load Balancer Controller."
  type        = bool
  default     = true
}

variable "enable_prometheus" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)."
  type        = bool
  default     = true
}

variable "enable_fluentbit" {
  description = "Install aws-for-fluent-bit for CloudWatch log aggregation."
  type        = bool
  default     = true
}
