output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for the cluster, for kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Cluster security group created/managed by EKS."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (null if disabled)."
  value       = local.oidc_provider_arn
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL without the https:// scheme (null if disabled)."
  value       = local.oidc_issuer_url
}

output "cluster_secrets_kms_key_arn" {
  description = "CMK ARN used for EKS secrets envelope encryption."
  value       = local.cluster_kms_key_arn
}

output "ebs_kms_key_arn" {
  description = "CMK ARN used for node EBS volume encryption."
  value       = local.ebs_kms_key_arn
}

output "cloudwatch_kms_key_arn" {
  description = "CMK ARN used for control-plane CloudWatch log encryption."
  value       = local.cloudwatch_kms_key_arn
}

output "node_ssh_key_names" {
  description = "EC2 key pair name per node group that has SSH enabled."
  value       = { for k, kp in aws_key_pair.node : k => kp.key_name }
}

output "node_ssh_secret_arns" {
  description = "Secrets Manager ARN holding each node group's SSH private key (empty if storage disabled)."
  value       = { for k, s in aws_secretsmanager_secret.node_ssh : k => s.arn }
}

output "node_ssh_private_keys" {
  description = "Generated SSH private keys per node group. Sensitive; prefer retrieving from Secrets Manager."
  value       = { for k, pk in tls_private_key.node : k => pk.private_key_openssh }
  sensitive   = true
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the control plane."
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "Shared IAM role ARN for managed node groups (null if no node groups)."
  value       = try(aws_iam_role.node[0].arn, null)
}

output "node_groups" {
  description = "Managed node group attributes keyed by name."
  value = {
    for k, ng in aws_eks_node_group.this : k => {
      arn           = ng.arn
      status        = ng.status
      capacity_type = ng.capacity_type
    }
  }
}

output "addon_role_arns" {
  description = "IAM role ARN per addon (Pod Identity or IRSA), null where the addon uses the node role."
  value       = local.addon_role_arn
}

output "node_iam_role_name" {
  description = "Name of the shared IAM role for managed node groups (used by Karpenter for node access entry)."
  value       = try(aws_iam_role.node[0].name, null)
}
