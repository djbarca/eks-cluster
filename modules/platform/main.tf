data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  cloudwatch_log_group = "${var.cloudwatch_log_group_prefix}/${var.cluster_name}"
}

resource "aws_eks_pod_identity_association" "lbc" {
  count           = var.enable_lbc ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc[0].arn
}

resource "aws_eks_pod_identity_association" "fluentbit" {
  count           = var.enable_fluentbit ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = "logging"
  service_account = "aws-for-fluent-bit"
  role_arn        = aws_iam_role.fluentbit[0].arn
}
