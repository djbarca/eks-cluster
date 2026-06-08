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
