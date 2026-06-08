###############################################################################
# Cluster IAM role
###############################################################################

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = merge(local.base_tags, {
    Name         = "${var.cluster_name}-cluster-role"
    role-purpose = "eks-control-plane"
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

###############################################################################
# CloudWatch log group for control-plane logs
###############################################################################

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cloudwatch_log_retention_in_days
  kms_key_id        = local.cloudwatch_kms_key_arn

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-control-plane-logs"
  })
}

###############################################################################
# Control plane
###############################################################################

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.enabled_cluster_log_types

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  encryption_config {
    provider {
      key_arn = local.cluster_kms_key_arn
    }
    resources = ["secrets"]
  }

  tags = merge(local.base_tags, {
    Name = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
    terraform_data.cluster_sg_cleanup,
  ]
}

# On destroy: after the cluster is deleted, AWS holds onto the EKS-managed
# cluster security group for a few minutes. If it's not released by the time
# Terraform tries to delete the VPC, the VPC deletion hangs. This provisioner
# waits up to 5 minutes for AWS to release it, then deletes it manually.
resource "terraform_data" "cluster_sg_cleanup" {
  input = var.cluster_name

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      CLUSTER_NAME="${self.input}"
      echo "Waiting for EKS cluster SG to be released by AWS..."
      ELAPSED=0
      while [ $ELAPSED -lt 300 ]; do
        SG_ID=$(aws ec2 describe-security-groups \
          --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
          --query 'SecurityGroups[0].GroupId' \
          --output text 2>/dev/null)
        if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
          echo "EKS cluster SG released."
          exit 0
        fi
        sleep 15
        ELAPSED=$((ELAPSED + 15))
      done
      echo "Timed out waiting — deleting EKS cluster SG $SG_ID manually."
      aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || true
    EOT
  }
}

###############################################################################
# OIDC provider (IRSA)
###############################################################################

data "tls_certificate" "oidc" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  count = var.enable_irsa ? 1 : 0

  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.${local.dns_suffix}"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-irsa"
  })
}

locals {
  oidc_provider_arn = var.enable_irsa ? aws_iam_openid_connect_provider.oidc[0].arn : null
  oidc_issuer_url   = var.enable_irsa ? replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "") : null
}
