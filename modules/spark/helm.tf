###############################################################################
# Spark Operator
# Manages SparkApplication and ScheduledSparkApplication CRDs.
###############################################################################

resource "helm_release" "spark_operator" {
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = "2.2.0"
  namespace        = "spark-operator"
  create_namespace = true

  values = [yamlencode({
    webhook = {
      enable = true
    }
    sparkJobNamespace = var.spark_namespace
  })]

  depends_on = [kubectl_manifest.spark_namespace]
}

###############################################################################
# YuniKorn — gang scheduler for Spark executor pods.
# Spark jobs opt in by setting schedulerName: yunikorn in SparkApplication spec.
###############################################################################

resource "helm_release" "yunikorn" {
  count            = var.enable_yunikorn ? 1 : 0
  name             = "yunikorn"
  repository       = "https://apache.github.io/yunikorn-release"
  chart            = "yunikorn"
  version          = "1.6.0"
  namespace        = "yunikorn"
  create_namespace = true
}

###############################################################################
# Spark History Server
# Reads completed job event logs from S3 and serves the Spark UI.
# Deployed as Kubernetes manifests since there is no canonical upstream Helm chart.
###############################################################################

resource "kubectl_manifest" "history_server_serviceaccount" {
  count = var.enable_history_server ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "spark-history-server"
      namespace = var.spark_namespace
    }
  })

  depends_on = [kubectl_manifest.spark_namespace]
}

resource "kubectl_manifest" "history_server_deployment" {
  count = var.enable_history_server ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "spark-history-server"
      namespace = var.spark_namespace
      labels    = { app = "spark-history-server" }
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "spark-history-server" } }
      template = {
        metadata = { labels = { app = "spark-history-server" } }
        spec = {
          serviceAccountName = "spark-history-server"
          containers = [{
            name  = "spark-history-server"
            image = "bitnami/spark:3.5.3"
            command = [
              "/opt/bitnami/spark/bin/spark-class",
              "org.apache.spark.deploy.history.HistoryServer",
            ]
            env = [
              {
                name  = "SPARK_HISTORY_OPTS"
                value = "-Dspark.history.fs.logDirectory=s3a://${var.history_server_bucket}/ -Dspark.history.ui.port=18080"
              },
            ]
            ports = [{ containerPort = 18080 }]
            resources = {
              requests = { cpu = "200m", memory = "512Mi" }
              limits   = { memory = "1Gi" }
            }
          }]
        }
      }
    }
  })

  depends_on = [
    kubectl_manifest.history_server_serviceaccount,
    aws_eks_pod_identity_association.spark_history_server[0],
  ]
}

resource "kubectl_manifest" "history_server_service" {
  count = var.enable_history_server ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "spark-history-server"
      namespace = var.spark_namespace
      labels    = { app = "spark-history-server" }
    }
    spec = {
      selector = { app = "spark-history-server" }
      ports    = [{ port = 18080, targetPort = 18080 }]
    }
  })

  depends_on = [kubectl_manifest.spark_namespace]
}
