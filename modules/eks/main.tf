data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# Derive the caller's role name from the STS session ARN, then look up the
# full IAM role ARN (including any IAM path, e.g. SSO roles under
# /aws-reserved/sso.amazonaws.com/). Falls back to var.admin_role_arn if set.
locals {
  _caller_role_name = try(regex("assumed-role/([^/]+)/", data.aws_caller_identity.current.arn)[0], null)
}

data "aws_iam_role" "caller" {
  count = var.admin_role_arn == null && local._caller_role_name != null ? 1 : 0
  name  = local._caller_role_name
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  dns_suffix = data.aws_partition.current.dns_suffix

  create_secrets_kms    = var.cluster_secrets_kms_key_arn == null
  create_ebs_kms        = var.ebs_kms_key_arn == null
  create_cloudwatch_kms = var.cloudwatch_kms_key_arn == null

  cluster_kms_key_arn    = var.cluster_secrets_kms_key_arn != null ? var.cluster_secrets_kms_key_arn : aws_kms_key.secrets[0].arn
  ebs_kms_key_arn        = var.ebs_kms_key_arn != null ? var.ebs_kms_key_arn : aws_kms_key.ebs[0].arn
  cloudwatch_kms_key_arn = var.cloudwatch_kms_key_arn != null ? var.cloudwatch_kms_key_arn : aws_kms_key.cloudwatch[0].arn

  admin_principal_arn = var.admin_role_arn != null ? var.admin_role_arn : try(data.aws_iam_role.caller[0].arn, null)

  base_tags = merge(var.tags, {
    "terraform-module"                            = "eks-cluster"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# Fail fast if cluster-admin access entry would be silently skipped:
# happens when caller is an IAM user (no "assumed-role/" in STS ARN) and
# no explicit var.admin_role_arn was passed. Without this guard the apply
# succeeds but nobody can kubectl into the cluster.
check "admin_principal_resolvable" {
  assert {
    condition     = !var.grant_developer_admin || local.admin_principal_arn != null
    error_message = "grant_developer_admin = true but admin principal could not be resolved. Set var.admin_role_arn explicitly — caller must be an assumed role (SSO/STS) for auto-derivation to work."
  }
}
