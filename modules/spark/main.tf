data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
}

# Pod Identity association for the Spark History Server.
resource "aws_eks_pod_identity_association" "spark_history_server" {
  count           = var.enable_history_server ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = var.spark_namespace
  service_account = "spark-history-server"
  role_arn        = aws_iam_role.spark_history_server[0].arn
}

# Pod Identity association for Spark driver/executor pods (the `spark` SA).
# Created only when the caller provides job_data_bucket_arns.
resource "aws_eks_pod_identity_association" "spark_job" {
  count           = length(var.job_data_bucket_arns) > 0 ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = var.spark_namespace
  service_account = "spark"
  role_arn        = aws_iam_role.spark_job[0].arn
}

# Spark namespace with ResourceQuota to cap Karpenter provisioning.
resource "kubectl_manifest" "spark_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.spark_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
  })
}

resource "kubectl_manifest" "spark_resource_quota" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ResourceQuota"
    metadata = {
      name      = "spark-quota"
      namespace = var.spark_namespace
    }
    spec = {
      hard = {
        "requests.cpu"    = var.spark_namespace_cpu_limit
        "requests.memory" = var.spark_namespace_memory_limit
      }
    }
  })

  depends_on = [kubectl_manifest.spark_namespace]
}
