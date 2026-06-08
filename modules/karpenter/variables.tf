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

variable "node_iam_role_name" {
  description = "Name of the existing node IAM role. Karpenter-launched nodes reuse this role."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs where Karpenter may provision nodes."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs attached to Karpenter-provisioned nodes."
  type        = list(string)
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version. Defaults to 1.10.0."
  type        = string
  default     = "1.10.0"
}

variable "karpenter_namespace" {
  description = "Kubernetes namespace to deploy Karpenter into."
  type        = string
  default     = "karpenter"
}

variable "node_pools" {
  description = <<-EOT
    Map of Karpenter NodePools to create. Each entry produces one NodePool and
    shares the single EC2NodeClass. Example:

      node_pools = {
        system = {
          instance_types = ["m6i.large"]
          labels         = { role = "system" }
          taints         = []
        }
        spark = {
          instance_types = ["r6i.2xlarge", "r6i.4xlarge"]
          labels         = { role = "spark" }
          taints         = [{ key = "role", value = "spark", effect = "NoSchedule" }]
        }
      }
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "on-demand")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    min_size = optional(number, 0)
    max_size = optional(number, 50)
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}
