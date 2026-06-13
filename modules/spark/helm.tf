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
    # Spark Operator v2.x: spark.jobNamespaces controls which namespaces the
    # controller watches AND where Role bindings are created. The v1 key
    # `sparkJobNamespace` is silently ignored.
    spark = {
      jobNamespaces = [var.spark_namespace]
    }
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
          # Download hadoop-aws + aws-sdk-bundle into a shared volume so the
          # main container (apache/spark) can use s3a:// without rebuilding.
          initContainers = [{
            name  = "fetch-s3a-jars"
            image = "curlimages/curl:8.10.1"
            command = ["sh", "-c"]
            args = [
              <<-EOSH
              set -e
              cd /jars
              # Spark 3.5.x ships with hadoop-client 3.3.4, so we match that.
              # The aws-java-sdk-bundle v1 rejects Pod Identity's 169.254.170.23
              # endpoint as "invalid host"; switching to the AWS SDK v2 bundle
              # (used by hadoop-aws 3.4.x) is invasive. Instead we pin AWS SDK
              # v1 at 1.12.367+ where the host restriction was relaxed and
              # AWS_CONTAINER_CREDENTIALS_FULL_URI works with link-local IPs.
              curl -sSL -o hadoop-aws-3.3.4.jar \
                https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar
              curl -sSL -o aws-java-sdk-bundle-1.12.788.jar \
                https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.788/aws-java-sdk-bundle-1.12.788.jar
              EOSH
            ]
            volumeMounts = [{ name = "extra-jars", mountPath = "/jars" }]
            resources = {
              requests = { cpu = "100m", memory = "128Mi" }
              limits   = { memory = "256Mi" }
            }
          }]
          containers = [{
            name  = "spark-history-server"
            image = "apache/spark:3.5.3"
            command = ["/opt/spark/sbin/start-history-server.sh"]
            env = [
              {
                name  = "SPARK_NO_DAEMONIZE"
                value = "true"
              },
              {
                name  = "SPARK_HISTORY_OPTS"
                value = join(" ", [
                  "-Dspark.history.fs.logDirectory=s3a://${var.history_server_bucket}/logs",
                  "-Dspark.history.ui.port=18080",
                  # Pod Identity provider — avoids the default chain which
                  # walks env vars + IMDS and fails to find creds.
                  "-Dspark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider",
                  "-Dspark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
                ])
              },
              {
                # Make spark-class pick up the downloaded jars at startup
                name  = "SPARK_DIST_CLASSPATH"
                value = "/opt/spark/extra-jars/*"
              },
            ]
            ports = [{ containerPort = 18080 }]
            volumeMounts = [{ name = "extra-jars", mountPath = "/opt/spark/extra-jars" }]
            resources = {
              requests = { cpu = "200m", memory = "512Mi" }
              limits   = { memory = "1Gi" }
            }
          }]
          volumes = [{
            name     = "extra-jars"
            emptyDir = {}
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
