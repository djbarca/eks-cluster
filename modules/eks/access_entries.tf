###############################################################################
# Access entries — replaces aws-auth ConfigMap management.
###############################################################################

resource "aws_eks_access_entry" "developer_admin" {
  count = var.grant_developer_admin && local.admin_principal_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
  type          = "STANDARD"

  tags = merge(local.base_tags, {
    Name         = "${var.cluster_name}-access-admin"
    role-purpose = "cluster-admin"
  })
}

resource "aws_eks_access_policy_association" "developer_admin" {
  count = var.grant_developer_admin && local.admin_principal_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.developer_admin]
}

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-access-${each.key}"
  })
}

resource "aws_eks_access_policy_association" "this" {
  for_each = {
    for pair in flatten([
      for entry_key, entry in var.access_entries : [
        for assoc_key, assoc in entry.policy_associations : {
          key           = "${entry_key}:${assoc_key}"
          principal_arn = entry.principal_arn
          policy_arn    = assoc.policy_arn
          access_scope  = assoc.access_scope
        }
      ]
    ]) : pair.key => pair
  }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = each.value.access_scope.namespaces
  }

  depends_on = [aws_eks_access_entry.this]
}

