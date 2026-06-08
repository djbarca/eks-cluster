###############################################################################
# Core / naming
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. Used as a prefix for most resources."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must start with a letter and contain only alphanumerics and hyphens (max 100 chars)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes control plane version (e.g. \"1.31\")."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources that support them."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking
###############################################################################

variable "vpc_id" {
  description = "VPC the cluster will be deployed into."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the EKS control plane and node groups. Provide at least two subnets in different AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnets in different AZs are required for EKS."
  }
}

variable "endpoint_public_access" {
  description = "Whether the cluster API server is reachable from the public internet."
  type        = bool
  default     = false
}

variable "endpoint_private_access" {
  description = "Whether the cluster API server is reachable from within the VPC."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (only used when endpoint_public_access is true)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_prefix_delegation" {
  description = "Enable VPC CNI prefix delegation to increase pod density per node. Recommended when running Spark workloads."
  type        = bool
  default     = false
}

###############################################################################
# IAM
###############################################################################

variable "enable_irsa" {
  description = "Create the OIDC provider so addons that don't support Pod Identity can use IRSA."
  type        = bool
  default     = true
}


variable "grant_developer_admin" {
  description = "Grant the Terraform caller's IAM role cluster admin via an access entry."
  type        = bool
  default     = true
}

variable "admin_role_arn" {
  description = "Full IAM role ARN to grant cluster admin. If null, derived automatically from the caller's identity via data.aws_iam_role (handles SSO roles with IAM paths)."
  type        = string
  default     = null
}

variable "authentication_mode" {
  description = "API authentication mode. API uses access entries exclusively; API_AND_CONFIG_MAP keeps the legacy aws-auth ConfigMap as a fallback."
  type        = string
  default     = "API"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be either \"API\" or \"API_AND_CONFIG_MAP\"."
  }
}

variable "access_entries" {
  description = <<-EOT
    Map of EKS access entries. Key is an arbitrary identifier. Example:

      access_entries = {
        admins = {
          principal_arn = "arn:aws:iam::111122223333:role/Admins"
          policy_associations = {
            admin = {
              policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
              access_scope = { type = "cluster" }
            }
          }
        }
      }
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default = {}
}

###############################################################################
# Encryption
###############################################################################

variable "cluster_secrets_kms_key_arn" {
  description = "ARN of an existing CMK for EKS secrets envelope encryption. If null, the module creates one."
  type        = string
  default     = null
}

variable "ebs_kms_key_arn" {
  description = "ARN of an existing CMK for node EBS volume encryption. If null, the module creates one."
  type        = string
  default     = null
}

variable "cloudwatch_kms_key_arn" {
  description = "ARN of an existing CMK for control-plane CloudWatch log encryption. If null, the module creates one."
  type        = string
  default     = null
}

variable "secrets_kms_extra_principals" {
  description = "Additional IAM principal ARNs granted data-plane use on the secrets CMK. Only applied to a module-created key."
  type        = list(string)
  default     = []
}

variable "ebs_kms_extra_principals" {
  description = "Additional IAM principal ARNs granted data-plane use on the EBS CMK. Only applied to a module-created key."
  type        = list(string)
  default     = []
}

variable "cloudwatch_kms_extra_principals" {
  description = "Additional IAM principal ARNs granted data-plane use on the CloudWatch CMK. Only applied to a module-created key."
  type        = list(string)
  default     = []
}

variable "kms_key_deletion_window_in_days" {
  description = "Deletion window for created CMKs."
  type        = number
  default     = 30
}

###############################################################################
# Logging
###############################################################################

variable "enabled_cluster_log_types" {
  description = "Control-plane log types shipped to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cloudwatch_log_retention_in_days" {
  description = "Retention for the control-plane CloudWatch log group."
  type        = number
  default     = 90
}

###############################################################################
# Managed node groups & SSH
###############################################################################

variable "node_groups" {
  description = <<-EOT
    Map of managed node groups. The AMI is resolved from SSM per group based on
    ami_type unless ami_id is set explicitly. Example:

      node_groups = {
        default = {
          instance_types = ["m6i.large"]
          desired_size   = 3
          min_size       = 2
          max_size       = 6
        }
      }
  EOT
  type = map(object({
    instance_types             = optional(list(string), ["m6i.large"])
    capacity_type              = optional(string, "ON_DEMAND")
    ami_type                   = optional(string, "AL2023_x86_64_STANDARD")
    ami_id                     = optional(string)
    disk_size_gib              = optional(number, 50)
    desired_size               = optional(number, 2)
    min_size                   = optional(number, 1)
    max_size                   = optional(number, 4)
    max_unavailable_percentage = optional(number, 33)
    labels                     = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
    subnet_ids  = optional(list(string))
    ssh_enabled = optional(bool, true)
  }))
  default = {}
}

variable "ssh_key_algorithm" {
  description = "Algorithm for generated SSH key pairs."
  type        = string
  default     = "ED25519"

  validation {
    condition     = contains(["ED25519", "RSA"], var.ssh_key_algorithm)
    error_message = "ssh_key_algorithm must be ED25519 or RSA."
  }
}

variable "ssh_rsa_bits" {
  description = "Key size when ssh_key_algorithm is RSA (ignored for ED25519)."
  type        = number
  default     = 4096
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed inbound on port 22. Empty list = no SSH ingress rule (key pairs still installed). Prefer SSM Session Manager."
  type        = list(string)
  default     = []
}

variable "store_ssh_keys_in_secrets_manager" {
  description = "Store generated SSH private keys in AWS Secrets Manager for retrieval without reading Terraform state."
  type        = bool
  default     = true
}

###############################################################################
# Addons
###############################################################################

variable "cluster_addons" {
  description = <<-EOT
    EKS managed addons. Set pod_identity = true to have the module create a
    Pod Identity association + role; set use_irsa = true for addons that still
    need IRSA. Provide a policy_arns list for the permissions the addon needs.

      cluster_addons = {
        vpc-cni = {
          pod_identity = true
          policy_arns  = ["arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"]
        }
        aws-ebs-csi-driver = {
          pod_identity = true
          policy_arns  = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
        }
      }
  EOT
  type = map(object({
    addon_version        = optional(string)
    resolve_conflicts    = optional(string, "OVERWRITE")
    configuration_values = optional(string)
    service_account      = optional(string)
    namespace            = optional(string, "kube-system")
    pod_identity         = optional(bool, false)
    use_irsa             = optional(bool, false)
    policy_arns          = optional(list(string), [])
    before_compute       = optional(bool, false)
  }))
  default = {}
}
