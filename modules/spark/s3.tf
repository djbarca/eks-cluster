data "aws_iam_policy_document" "spark_history_server_s3" {
  count = var.enable_history_server ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.history_server_bucket_arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.history_server_bucket_arn]
  }
}

resource "aws_iam_role_policy" "spark_history_server_s3" {
  count  = var.enable_history_server ? 1 : 0
  name   = "s3-history-read"
  role   = aws_iam_role.spark_history_server[0].name
  policy = data.aws_iam_policy_document.spark_history_server_s3[0].json
}

###############################################################################
# Spark job S3 access — read/write to each bucket in job_data_bucket_arns
###############################################################################

data "aws_iam_policy_document" "spark_job_s3" {
  count = length(var.job_data_bucket_arns) > 0 ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [for arn in var.job_data_bucket_arns : "${arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = var.job_data_bucket_arns
  }
}

resource "aws_iam_role_policy" "spark_job_s3" {
  count  = length(var.job_data_bucket_arns) > 0 ? 1 : 0
  name   = "s3-job-data"
  role   = aws_iam_role.spark_job[0].name
  policy = data.aws_iam_policy_document.spark_job_s3[0].json
}
