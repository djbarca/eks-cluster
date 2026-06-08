###############################################################################
# KMS — three purpose-specific CMKs
#   * secrets    -> EKS envelope encryption of Kubernetes secrets
#   * ebs        -> node EBS volume encryption (managed node groups)
#   * cloudwatch -> control-plane CloudWatch log group encryption
#
# Each key is skipped if the caller supplies an ARN override.
# Key rotation is enabled; deletion window is configurable.
#
# Service principals are NOT covered by account-root (kms:*) delegation, so each
# policy explicitly grants the service principals that need the key.
###############################################################################

# ---- shared base statement (root admin) ------------------------------------
data "aws_iam_policy_document" "kms_base" {
  statement {
    sid       = "AllowRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

###############################################################################
# Secrets CMK
###############################################################################

data "aws_iam_policy_document" "kms_secrets" {
  count                   = local.create_secrets_kms ? 1 : 0
  source_policy_documents = [data.aws_iam_policy_document.kms_base.json]

  statement {
    sid    = "AllowEKSSecretsEncryption"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:ListGrants",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["eks.${local.dns_suffix}"]
    }
  }

  dynamic "statement" {
    for_each = length(var.secrets_kms_extra_principals) > 0 ? [1] : []
    content {
      sid    = "AllowExtraPrincipals"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.secrets_kms_extra_principals
      }
    }
  }
}

resource "aws_kms_key" "secrets" {
  count = local.create_secrets_kms ? 1 : 0

  description             = "EKS secrets envelope-encryption CMK for ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_secrets[0].json

  tags = merge(local.base_tags, {
    Name        = "${var.cluster_name}-secrets-cmk"
    key-purpose = "eks-secrets"
  })
}

resource "aws_kms_alias" "secrets" {
  count = local.create_secrets_kms ? 1 : 0

  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

###############################################################################
# EBS CMK (node volumes)
#   Managed node groups launch via an EC2 Auto Scaling group, so the
#   AWSServiceRoleForAutoScaling service-linked role must be able to use the key
#   and create grants for attaching encrypted volumes.
###############################################################################

data "aws_iam_policy_document" "kms_ebs" {
  count                   = local.create_ebs_kms ? 1 : 0
  source_policy_documents = [data.aws_iam_policy_document.kms_base.json]

  statement {
    sid    = "AllowEBSEncryptionUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }

  statement {
    sid    = "AllowAutoScalingUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.${local.dns_suffix}/AWSServiceRoleForAutoScaling"]
    }
  }

  statement {
    sid       = "AllowAutoScalingCreateGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.${local.dns_suffix}/AWSServiceRoleForAutoScaling"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  dynamic "statement" {
    for_each = length(var.ebs_kms_extra_principals) > 0 ? [1] : []
    content {
      sid    = "AllowExtraPrincipals"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.ebs_kms_extra_principals
      }
    }
  }
}

resource "aws_kms_key" "ebs" {
  count = local.create_ebs_kms ? 1 : 0

  description             = "EKS node EBS volume CMK for ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_ebs[0].json

  tags = merge(local.base_tags, {
    Name        = "${var.cluster_name}-ebs-cmk"
    key-purpose = "node-ebs"
  })
}

resource "aws_kms_alias" "ebs" {
  count = local.create_ebs_kms ? 1 : 0

  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}

###############################################################################
# CloudWatch CMK (control-plane logs)
###############################################################################

data "aws_iam_policy_document" "kms_cloudwatch" {
  count                   = local.create_cloudwatch_kms ? 1 : 0
  source_policy_documents = [data.aws_iam_policy_document.kms_base.json]

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.${local.dns_suffix}"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster"]
    }
  }

  dynamic "statement" {
    for_each = length(var.cloudwatch_kms_extra_principals) > 0 ? [1] : []
    content {
      sid    = "AllowExtraPrincipals"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.cloudwatch_kms_extra_principals
      }
    }
  }
}

resource "aws_kms_key" "cloudwatch" {
  count = local.create_cloudwatch_kms ? 1 : 0

  description             = "EKS control-plane CloudWatch logs CMK for ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_cloudwatch[0].json

  tags = merge(local.base_tags, {
    Name        = "${var.cluster_name}-cloudwatch-cmk"
    key-purpose = "cloudwatch-logs"
  })
}

resource "aws_kms_alias" "cloudwatch" {
  count = local.create_cloudwatch_kms ? 1 : 0

  name          = "alias/${var.cluster_name}-cloudwatch"
  target_key_id = aws_kms_key.cloudwatch[0].key_id
}
