###############################################################################
# AWS Load Balancer Controller
###############################################################################

resource "helm_release" "lbc" {
  count            = var.enable_lbc ? 1 : 0
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.12.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    clusterName  = var.cluster_name
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    vpcId = var.vpc_id
  })]

  depends_on = [aws_eks_pod_identity_association.lbc]
}


###############################################################################
# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
###############################################################################

resource "helm_release" "prometheus" {
  count            = var.enable_prometheus ? 1 : 0
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "70.3.0"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      persistence = {
        enabled          = var.grafana_storage_size != ""
        storageClassName = var.grafana_storage_size != "" ? "gp2" : null
        size             = var.grafana_storage_size != "" ? var.grafana_storage_size : null
      }
    }
    prometheus = {
      prometheusSpec = {
        retention = "15d"
      }
    }
  })]
}

###############################################################################
# AWS for Fluent Bit
# Uses cloudWatchLogs (native plugin) — cloudWatch (Go plugin) rejects
# the Pod Identity credential endpoint (link-local 169.254.170.23).
###############################################################################

resource "helm_release" "fluentbit" {
  count            = var.enable_fluentbit ? 1 : 0
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  version          = "0.1.35"
  namespace        = "logging"
  create_namespace = true

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "aws-for-fluent-bit"
    }
    cloudWatch    = { enabled = false }
    cloudWatchLogs = {
      enabled          = true
      region           = var.aws_region
      logGroupName     = local.cloudwatch_log_group
      logStreamPrefix  = "fluentbit-"
      autoCreateGroup  = true
    }
    firehose      = { enabled = false }
    kinesis       = { enabled = false }
    elasticsearch = { enabled = false }
  })]

  depends_on = [aws_eks_pod_identity_association.fluentbit]
}
