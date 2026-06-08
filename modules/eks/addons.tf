###############################################################################
# Addon IAM roles
#   Two trust models, selected per addon:
#     * pod_identity = true  -> role trusts pods.eks.amazonaws.com (Pod Identity)
#     * use_irsa     = true  -> role trusts the cluster OIDC provider (IRSA)
#   An addon may set neither (runs on the node role) but not both.
###############################################################################

locals {
  pod_identity_addons = {
    for k, a in var.cluster_addons : k => a if a.pod_identity
  }
  irsa_addons = {
    for k, a in var.cluster_addons : k => a if a.use_irsa
  }
}

# ---- Pod Identity trust ----------------------------------------------------
data "aws_iam_policy_document" "addon_pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "addon_pod_identity" {
  for_each = local.pod_identity_addons

  name               = "${var.cluster_name}-addon-${each.key}-pi"
  assume_role_policy = data.aws_iam_policy_document.addon_pod_identity_assume.json

  tags = merge(local.base_tags, {
    Name         = "${var.cluster_name}-addon-${each.key}-pi"
    role-purpose = "eks-addon-pod-identity"
    addon        = each.key
  })
}

resource "aws_iam_role_policy_attachment" "addon_pod_identity" {
  for_each = {
    for pair in flatten([
      for name, a in local.pod_identity_addons : [
        for arn in a.policy_arns : {
          key  = "${name}:${arn}"
          name = name
          arn  = arn
        }
      ]
    ]) : pair.key => pair
  }

  role       = aws_iam_role.addon_pod_identity[each.value.name].name
  policy_arn = each.value.arn
}

# ---- IRSA trust ------------------------------------------------------------
data "aws_iam_policy_document" "addon_irsa_assume" {
  for_each = var.enable_irsa ? local.irsa_addons : {}

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_url}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_url}:aud"
      values   = ["sts.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "addon_irsa" {
  for_each = var.enable_irsa ? local.irsa_addons : {}

  name               = "${var.cluster_name}-addon-${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.addon_irsa_assume[each.key].json

  tags = merge(local.base_tags, {
    Name         = "${var.cluster_name}-addon-${each.key}-irsa"
    role-purpose = "eks-addon-irsa"
    addon        = each.key
  })
}

resource "aws_iam_role_policy_attachment" "addon_irsa" {
  for_each = var.enable_irsa ? {
    for pair in flatten([
      for name, a in local.irsa_addons : [
        for arn in a.policy_arns : {
          key  = "${name}:${arn}"
          name = name
          arn  = arn
        }
      ]
    ]) : pair.key => pair
  } : {}

  role       = aws_iam_role.addon_irsa[each.value.name].name
  policy_arn = each.value.arn
}

locals {
  addon_role_arn = {
    for k, a in var.cluster_addons : k => (
      a.pod_identity ? aws_iam_role.addon_pod_identity[k].arn :
      (a.use_irsa && var.enable_irsa ? aws_iam_role.addon_irsa[k].arn : null)
    )
  }

  before_compute_addons = { for k, a in var.cluster_addons : k => a if a.before_compute }
  after_compute_addons  = { for k, a in var.cluster_addons : k => a if !a.before_compute }
}

###############################################################################
# Latest addon version lookup (used when addon_version is not pinned)
###############################################################################

data "aws_eks_addon_version" "latest" {
  for_each = var.cluster_addons

  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

locals {
  resolved_addon_version = {
    for k, a in var.cluster_addons : k =>
      coalesce(a.addon_version, data.aws_eks_addon_version.latest[k].version)
  }
}

locals {
  vpc_cni_configuration_values = var.enable_prefix_delegation ? jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  }) : null
}

###############################################################################
# Addon installation
###############################################################################

resource "aws_eks_addon" "before_compute" {
  for_each = local.before_compute_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = local.resolved_addon_version[each.key]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = each.value.resolve_conflicts
  configuration_values        = each.key == "vpc-cni" && local.vpc_cni_configuration_values != null ? local.vpc_cni_configuration_values : each.value.configuration_values

  service_account_role_arn = each.value.use_irsa ? local.addon_role_arn[each.key] : null

  dynamic "pod_identity_association" {
    for_each = each.value.pod_identity ? [1] : []
    content {
      role_arn        = local.addon_role_arn[each.key]
      service_account = each.value.service_account
    }
  }

  tags = local.base_tags

  depends_on = [aws_eks_access_policy_association.this]
}

resource "aws_eks_addon" "after_compute" {
  for_each = local.after_compute_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = local.resolved_addon_version[each.key]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = each.value.resolve_conflicts
  configuration_values        = each.value.configuration_values

  service_account_role_arn = each.value.use_irsa ? local.addon_role_arn[each.key] : null

  dynamic "pod_identity_association" {
    for_each = each.value.pod_identity ? [1] : []
    content {
      role_arn        = local.addon_role_arn[each.key]
      service_account = each.value.service_account
    }
  }

  tags = local.base_tags

  depends_on = [aws_eks_node_group.this]
}
