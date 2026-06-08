data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spark_history_server" {
  count              = var.enable_history_server ? 1 : 0
  name               = "${var.cluster_name}-spark-history-server"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-spark-history-server"
    role-purpose = "spark-history-server"
  })

  lifecycle {
    precondition {
      condition     = var.history_server_bucket != "" && var.history_server_bucket_arn != ""
      error_message = "history_server_bucket and history_server_bucket_arn must be set when enable_history_server = true."
    }
  }
}
