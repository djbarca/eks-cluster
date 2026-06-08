# Platform + Spark Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `modules/platform/` (AWS LBC, kube-prometheus-stack, Fluent Bit) and `modules/spark/` (Spark Operator, YuniKorn, Spark History Server) and wire both into the environment configs.

**Architecture:** Both modules follow the exact same pattern as `modules/karpenter/`: IAM roles via `aws_iam_policy_document`, Helm releases via `helm_release`, Kubernetes resources via `kubectl_manifest`, Pod Identity for AWS credentials. No `required_providers` in module `versions.tf` — providers are declared in the calling environment's `versions.tf`.

**Tech Stack:** Terraform >= 1.9, AWS provider ~> 6.0, Helm provider ~> 2.0, alekc/kubectl ~> 2.0. Helm charts: `aws/aws-load-balancer-controller`, `prometheus-community/kube-prometheus-stack`, `aws/aws-for-fluent-bit`, Spark Operator OCI, `apache/yunikorn`.

---

## File Map

### Created
- `modules/platform/versions.tf`
- `modules/platform/variables.tf`
- `modules/platform/main.tf` — data sources, locals, Pod Identity associations
- `modules/platform/iam.tf` — LBC + Fluent Bit IAM roles and policies
- `modules/platform/helm.tf` — all three Helm releases
- `modules/platform/outputs.tf`
- `modules/spark/versions.tf`
- `modules/spark/variables.tf`
- `modules/spark/main.tf` — data sources, locals, Pod Identity association, spark namespace + ResourceQuota
- `modules/spark/iam.tf` — Spark History Server IAM role
- `modules/spark/s3.tf` — S3 read policy for History Server
- `modules/spark/helm.tf` — Spark Operator, YuniKorn, History Server Deployment
- `modules/spark/outputs.tf`

### Modified
- `environments/dev/cluster-1/main.tf` — add `module.platform` + `module.spark`
- `environments/dev/cluster-1/variables.tf` — new file: `grafana_admin_password`, `spark_history_bucket`, `spark_history_bucket_arn`
- `environments/test/cluster-1/main.tf` — add module calls (stubs, same pattern as dev)
- `environments/prod/cluster-1/main.tf` — add module calls (prod sizing)
- `CLAUDE.md` — update deploy order for platform + spark

---

### Task 1: Scaffold `modules/platform/` (versions, variables, main, outputs)

**Files:**
- Create: `modules/platform/versions.tf`
- Create: `modules/platform/variables.tf`
- Create: `modules/platform/main.tf`
- Create: `modules/platform/outputs.tf`

- [ ] **Step 1: Create `modules/platform/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"
}
```

- [ ] **Step 2: Create `modules/platform/variables.tf`**

```hcl
variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — used by the AWS Load Balancer Controller for subnet discovery."
  type        = string
}

variable "aws_region" {
  description = "AWS region for Fluent Bit CloudWatch target."
  type        = string
}

variable "grafana_storage_size" {
  description = "Grafana PVC size. Empty string = ephemeral (no PVC). E.g. \"20Gi\" enables an EBS-backed PVC."
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "cloudwatch_log_group_prefix" {
  description = "CloudWatch log group prefix. Full path = <prefix>/<cluster_name>."
  type        = string
  default     = "/eks"
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 3: Create `modules/platform/main.tf`**

```hcl
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
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = var.cluster_name
  namespace       = "logging"
  service_account = "aws-for-fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
}
```

- [ ] **Step 4: Create `modules/platform/outputs.tf`**

```hcl
output "lbc_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role."
  value       = aws_iam_role.lbc.arn
}

output "fluentbit_role_arn" {
  description = "ARN of the Fluent Bit IAM role."
  value       = aws_iam_role.fluentbit.arn
}
```

- [ ] **Step 5: Verify directory exists**

```bash
ls /Users/dmaposa/projects/eks-cluster/modules/platform/
```

Expected: `main.tf  outputs.tf  variables.tf  versions.tf`

---

### Task 2: Create `modules/platform/iam.tf`

**Files:**
- Create: `modules/platform/iam.tf`

- [ ] **Step 1: Write the file**

```hcl
###############################################################################
# Shared Pod Identity trust policy
###############################################################################

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

###############################################################################
# AWS Load Balancer Controller
###############################################################################

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-lbc"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-lbc"
    role-purpose = "aws-load-balancer-controller"
  })
}

data "aws_iam_policy_document" "lbc" {
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPoolClient",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "shield:DescribeProtection",
      "shield:GetSubscriptionState",
      "shield:DeleteProtection",
      "shield:CreateProtection",
      "shield:DescribeSubscription",
      "shield:ListProtections",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:*:*:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:${local.partition}:ec2:*:*:security-group/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*"]
  }
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-lbc"
  policy = data.aws_iam_policy_document.lbc.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

###############################################################################
# Fluent Bit
###############################################################################

resource "aws_iam_role" "fluentbit" {
  name               = "${var.cluster_name}-fluentbit"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-fluentbit"
    role-purpose = "fluent-bit"
  })
}

data "aws_iam_policy_document" "fluentbit" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.cloudwatch_log_group}*"]
  }
}

resource "aws_iam_role_policy" "fluentbit" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.fluentbit.name
  policy = data.aws_iam_policy_document.fluentbit.json
}
```

---

### Task 3: Create `modules/platform/helm.tf`

**Files:**
- Create: `modules/platform/helm.tf`

Note: Before writing this file, look up the latest chart versions by running:
```bash
helm repo add eks https://aws.github.io/eks-charts && helm search repo eks/aws-load-balancer-controller --versions | head -3
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm search repo prometheus-community/kube-prometheus-stack --versions | head -3
```
Use the latest stable version found. The versions below (`1.12.0`, `70.3.0`, `0.1.35`) are starting points — update to latest before committing.

- [ ] **Step 1: Write the file**

```hcl
###############################################################################
# AWS Load Balancer Controller
###############################################################################

resource "helm_release" "lbc" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.12.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    clusterName = var.cluster_name
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
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "70.3.0"
  namespace        = "monitoring"
  create_namespace = true

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      persistence = var.grafana_storage_size == "" ? {
        enabled = false
      } : {
        enabled          = true
        storageClassName = "gp2"
        size             = var.grafana_storage_size
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
###############################################################################

resource "helm_release" "fluentbit" {
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
    cloudWatch = {
      enabled  = true
      region   = var.aws_region
      logGroup = local.cloudwatch_log_group
    }
    firehose  = { enabled = false }
    kinesis   = { enabled = false }
    elasticsearch = { enabled = false }
  })]

  depends_on = [aws_eks_pod_identity_association.fluentbit]
}
```

- [ ] **Step 2: Validate `modules/platform/`**

```bash
cd /Users/dmaposa/projects/eks-cluster/modules/platform && terraform init -backend=false && terraform validate 2>&1
```

Expected: `Success! The configuration is valid`

---

### Task 4: Scaffold `modules/spark/` (versions, variables, main, outputs)

**Files:**
- Create: `modules/spark/versions.tf`
- Create: `modules/spark/variables.tf`
- Create: `modules/spark/main.tf`
- Create: `modules/spark/outputs.tf`

- [ ] **Step 1: Create `modules/spark/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"
}
```

- [ ] **Step 2: Create `modules/spark/variables.tf`**

```hcl
variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster."
  type        = string
}

variable "history_server_bucket" {
  description = "Name of the S3 bucket holding Spark job history (caller-managed — module does not create it)."
  type        = string
}

variable "history_server_bucket_arn" {
  description = "ARN of the S3 bucket holding Spark job history (used to scope the IAM policy)."
  type        = string
}

variable "spark_namespace" {
  description = "Kubernetes namespace for Spark job submissions."
  type        = string
  default     = "spark"
}

variable "spark_namespace_cpu_limit" {
  description = "ResourceQuota CPU limit for the Spark namespace."
  type        = string
  default     = "500"
}

variable "spark_namespace_memory_limit" {
  description = "ResourceQuota memory limit for the Spark namespace."
  type        = string
  default     = "2000Gi"
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 3: Create `modules/spark/main.tf`**

```hcl
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
  cluster_name    = var.cluster_name
  namespace       = var.spark_namespace
  service_account = "spark-history-server"
  role_arn        = aws_iam_role.spark_history_server.arn
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
```

- [ ] **Step 4: Create `modules/spark/outputs.tf`**

```hcl
output "spark_history_server_role_arn" {
  description = "ARN of the Spark History Server IAM role."
  value       = aws_iam_role.spark_history_server.arn
}

output "spark_namespace" {
  description = "Name of the Spark Kubernetes namespace."
  value       = var.spark_namespace
}
```

---

### Task 5: Create `modules/spark/iam.tf` and `modules/spark/s3.tf`

**Files:**
- Create: `modules/spark/iam.tf`
- Create: `modules/spark/s3.tf`

- [ ] **Step 1: Create `modules/spark/iam.tf`**

```hcl
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
  name               = "${var.cluster_name}-spark-history-server"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-spark-history-server"
    role-purpose = "spark-history-server"
  })
}
```

- [ ] **Step 2: Create `modules/spark/s3.tf`**

```hcl
data "aws_iam_policy_document" "spark_history_server_s3" {
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
  name   = "s3-history-read"
  role   = aws_iam_role.spark_history_server.name
  policy = data.aws_iam_policy_document.spark_history_server_s3.json
}
```

---

### Task 6: Create `modules/spark/helm.tf`

**Files:**
- Create: `modules/spark/helm.tf`

Note: Before writing, look up latest chart versions:
```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator && helm search repo spark-operator --versions | head -3
helm repo add yunikorn https://apache.github.io/yunikorn-release && helm search repo yunikorn --versions | head -3
```
The versions below (`2.2.0`, `1.6.0`) are starting points — update to latest before committing.

- [ ] **Step 1: Write the file**

```hcl
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
# Deployed as a Kubernetes Deployment + Service via kubectl_manifest since
# there is no canonical upstream Helm chart.
###############################################################################

resource "kubectl_manifest" "history_server_serviceaccount" {
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
            image = "apache/spark:3.5.3"
            command = [
              "/opt/spark/bin/spark-class",
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
    aws_eks_pod_identity_association.spark_history_server,
  ]
}

resource "kubectl_manifest" "history_server_service" {
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
```

- [ ] **Step 2: Validate `modules/spark/`**

```bash
cd /Users/dmaposa/projects/eks-cluster/modules/spark && terraform init -backend=false && terraform validate 2>&1
```

Expected: `Success! The configuration is valid`

---

### Task 7: Update `environments/dev/cluster-1/`

**Files:**
- Create: `environments/dev/cluster-1/variables.tf`
- Modify: `environments/dev/cluster-1/main.tf`

- [ ] **Step 1: Create `environments/dev/cluster-1/variables.tf`**

```hcl
variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "spark_history_bucket" {
  description = "Name of the S3 bucket for Spark History Server event logs."
  type        = string
}

variable "spark_history_bucket_arn" {
  description = "ARN of the S3 bucket for Spark History Server event logs."
  type        = string
}
```

- [ ] **Step 2: Append `module "platform"` and `module "spark"` to `environments/dev/cluster-1/main.tf`**

Read the file first, then append after the closing `}` of `module "karpenter"`:

```hcl
###############################################################################
# Platform (LBC, Prometheus/Grafana, Fluent Bit)
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = "us-east-1"
  grafana_storage_size               = ""
  grafana_admin_password             = var.grafana_admin_password

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}

###############################################################################
# Spark (Spark Operator, YuniKorn, History Server)
###############################################################################

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  history_server_bucket              = var.spark_history_bucket
  history_server_bucket_arn          = var.spark_history_bucket_arn

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}
```

- [ ] **Step 3: Init and validate dev environment**

```bash
cd /Users/dmaposa/projects/eks-cluster/environments/dev/cluster-1 && terraform init && terraform validate 2>&1
```

Expected: `Success! The configuration is valid`

---

### Task 8: Update `environments/test/` and `environments/prod/` stubs

**Files:**
- Modify: `environments/test/cluster-1/main.tf`
- Create: `environments/test/cluster-1/variables.tf`
- Modify: `environments/prod/cluster-1/main.tf`
- Create: `environments/prod/cluster-1/variables.tf`

- [ ] **Step 1: Add `variables.tf` to test (identical to dev)**

Create `environments/test/cluster-1/variables.tf` with the same content as dev:

```hcl
variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "spark_history_bucket" {
  description = "Name of the S3 bucket for Spark History Server event logs."
  type        = string
}

variable "spark_history_bucket_arn" {
  description = "ARN of the S3 bucket for Spark History Server event logs."
  type        = string
}
```

- [ ] **Step 2: Append module calls to `environments/test/cluster-1/main.tf`**

Append after the `module "karpenter"` block:

```hcl
###############################################################################
# Platform
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = "us-east-1"
  grafana_storage_size               = ""
  grafana_admin_password             = var.grafana_admin_password

  tags = { Environment = "test", Team = "data-platform" }
}

###############################################################################
# Spark
###############################################################################

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  history_server_bucket              = var.spark_history_bucket
  history_server_bucket_arn          = var.spark_history_bucket_arn

  tags = { Environment = "test", Team = "data-platform" }
}
```

- [ ] **Step 3: Add `variables.tf` to prod (identical to dev/test)**

Create `environments/prod/cluster-1/variables.tf` with the same content as test.

- [ ] **Step 4: Append module calls to `environments/prod/cluster-1/main.tf`**

Append after the `module "karpenter"` block. Prod uses Grafana EBS storage:

```hcl
###############################################################################
# Platform
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = "us-east-1"
  grafana_storage_size               = "20Gi"
  grafana_admin_password             = var.grafana_admin_password

  tags = { Environment = "prod", Team = "data-platform" }
}

###############################################################################
# Spark
###############################################################################

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  history_server_bucket              = var.spark_history_bucket
  history_server_bucket_arn          = var.spark_history_bucket_arn

  tags = { Environment = "prod", Team = "data-platform" }
}
```

---

### Task 9: Update `CLAUDE.md` deploy order

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Commands section in CLAUDE.md**

Find the "Deploy a cluster" block and replace it with:

```markdown
# Deploy a cluster — three phases:
# Phase 1: VPC + EKS infra
terraform -chdir=environments/dev/cluster-1 apply -target=module.vpc -target=module.eks

# Phase 2: Karpenter + platform/spark IAM roles (no Helm yet)
terraform -chdir=environments/dev/cluster-1 apply \
  -target=module.karpenter \
  -target=module.platform.aws_iam_role.lbc \
  -target=module.platform.aws_iam_role.fluentbit \
  -target=module.spark.aws_iam_role.spark_history_server

# Phase 3: All Helm releases and Kubernetes resources
terraform -chdir=environments/dev/cluster-1 apply

# Subsequent applies (cluster exists) — single apply works
terraform -chdir=environments/dev/cluster-1 apply
```

---

### Task 10: Final validation

- [ ] **Step 1: Validate all roots**

```bash
terraform -chdir=/Users/dmaposa/projects/eks-cluster/modules/platform validate 2>&1
terraform -chdir=/Users/dmaposa/projects/eks-cluster/modules/spark validate 2>&1
terraform -chdir=/Users/dmaposa/projects/eks-cluster/environments/dev/cluster-1 validate 2>&1
terraform -chdir=/Users/dmaposa/projects/eks-cluster/environments/test/cluster-1 init -backend=false && terraform -chdir=/Users/dmaposa/projects/eks-cluster/environments/test/cluster-1 validate 2>&1
terraform -chdir=/Users/dmaposa/projects/eks-cluster/environments/prod/cluster-1 init -backend=false && terraform -chdir=/Users/dmaposa/projects/eks-cluster/environments/prod/cluster-1 validate 2>&1
```

Expected: all five return `Success! The configuration is valid`

- [ ] **Step 2: Format check**

```bash
terraform fmt -recursive -check /Users/dmaposa/projects/eks-cluster/modules/platform/
terraform fmt -recursive -check /Users/dmaposa/projects/eks-cluster/modules/spark/
```

Fix any formatting issues with `terraform fmt -recursive`.
