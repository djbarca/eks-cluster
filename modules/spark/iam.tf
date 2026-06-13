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

###############################################################################
# Spark job IAM role
#   Pod Identity-attached role for Spark driver and executor pods running under
#   the `spark` service account in var.spark_namespace. Created only when the
#   caller passes one or more S3 bucket ARNs via job_data_bucket_arns.
###############################################################################

resource "aws_iam_role" "spark_job" {
  count              = length(var.job_data_bucket_arns) > 0 ? 1 : 0
  name               = "${var.cluster_name}-spark-job"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-spark-job"
    role-purpose = "spark-job"
  })
}
