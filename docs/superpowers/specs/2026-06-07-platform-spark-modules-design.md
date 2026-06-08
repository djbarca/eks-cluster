# Platform + Spark Modules Design

**Date:** 2026-06-07
**Status:** Approved

---

## Context

The repo currently has `modules/eks/` (EKS cluster) and `modules/karpenter/` (node autoscaling). This design adds the next two layers:

- `modules/platform/` — core cluster services needed by all workloads
- `modules/spark/` — Spark-specific components for data processing

Both modules follow the same patterns established by `modules/karpenter/`: IAM roles created inline, Helm charts via `helm_release`, Kubernetes resources via `kubectl_manifest`, no permissions boundary, Pod Identity for AWS credential delivery.

---

## Repository Structure Changes

```
modules/
  eks/           # unchanged
  karpenter/     # unchanged
  platform/      # new
    versions.tf
    variables.tf
    main.tf
    iam.tf
    helm.tf
    outputs.tf
  spark/         # new
    versions.tf
    variables.tf
    main.tf
    iam.tf
    s3.tf
    helm.tf
    outputs.tf
```

Environment configs add two module calls after `module.karpenter`:

```hcl
module "platform" {
  source = "../../../modules/platform"
  ...
  grafana_storage_size = ""        # dev: ephemeral; prod: "20Gi"
}

module "spark" {
  source = "../../../modules/spark"
  ...
  history_server_bucket     = "my-spark-history-bucket"
  history_server_bucket_arn = "arn:aws:s3:::my-spark-history-bucket"
}
```

---

## Module: `modules/platform/`

### Purpose

Installs cluster-wide services that all workloads depend on: ingress/load balancing, monitoring, and log aggregation. These run on every cluster regardless of what data workloads are deployed.

### Components

| Component | Helm chart | Namespace |
|---|---|---|
| AWS Load Balancer Controller | `eks/aws-load-balancer-controller` | `kube-system` |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `monitoring` |
| aws-for-fluent-bit | `aws/aws-for-fluent-bit` | `logging` |

### IAM (`iam.tf`)

**Load Balancer Controller role:**
- Trust: `pods.eks.amazonaws.com`
- Policy: `arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy` (AWS managed)
- Pod Identity association: service account `aws-load-balancer-controller` in `kube-system`

**Fluent Bit role:**
- Trust: `pods.eks.amazonaws.com`
- Inline policy: `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`, `logs:DescribeLogStreams` on `arn:aws:logs:*:*:log-group:/eks/<cluster_name>*`
- Pod Identity association: service account `aws-for-fluent-bit` in `logging`

### Helm (`helm.tf`)

**AWS Load Balancer Controller:**
- Configured with `clusterName` and `serviceAccount.annotations` (empty — Pod Identity needs no annotation)
- Replica count: 2 for HA

**kube-prometheus-stack:**
- Grafana storage controlled by `var.grafana_storage_size`:
  - `""` → `persistence.enabled = false` (ephemeral)
  - non-empty → `persistence.enabled = true`, `persistence.size = var.grafana_storage_size`, `storageClassName = gp3`
- Prometheus retention: 15 days
- Default Grafana admin password via variable (sensitive)

**aws-for-fluent-bit:**
- Configured to ship to CloudWatch log group `/eks/<cluster_name>`
- Region from `var.aws_region`

### Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `cluster_name` | string | — | EKS cluster name |
| `cluster_endpoint` | string | — | API server endpoint |
| `cluster_certificate_authority_data` | string | — | Base64 CA cert |
| `vpc_id` | string | — | VPC ID for LB Controller subnet discovery |
| `aws_region` | string | — | AWS region for Fluent Bit CloudWatch target |
| `grafana_storage_size` | string | `""` | Empty = ephemeral, e.g. `"20Gi"` = EBS PVC |
| `grafana_admin_password` | string | — | Grafana admin password (sensitive) |
| `cloudwatch_log_group_prefix` | string | `/eks` | Log group prefix; full path = `<prefix>/<cluster_name>` |
| `tags` | map(string) | `{}` | Tags for AWS resources |

### Outputs

- `lbc_role_arn` — Load Balancer Controller IAM role ARN
- `fluentbit_role_arn` — Fluent Bit IAM role ARN

---

## Module: `modules/spark/`

### Purpose

Installs Spark-specific workload tooling: the Spark Operator for job lifecycle management, YuniKorn for gang scheduling, and the Spark History Server for post-job debugging. Creates and configures the `spark` namespace with resource quotas.

### Components

| Component | Helm chart | Namespace |
|---|---|---|
| Spark Operator | `spark-operator/spark-operator` | `spark-operator` |
| YuniKorn | `yunikorn/yunikorn` | `yunikorn` |
| Spark History Server | `helm.sh/spark-history-server` | `spark` |

### Namespace (`helm.tf`)

The module creates the `spark` namespace with a `ResourceQuota` to prevent runaway jobs from consuming all Karpenter capacity. Quota limits are configurable via variables with sensible defaults.

### IAM (`iam.tf` + `s3.tf`)

**Spark History Server role:**
- Trust: `pods.eks.amazonaws.com`
- Inline policy (defined in `s3.tf`): `s3:GetObject`, `s3:ListBucket` scoped to `var.history_server_bucket_arn`
- Pod Identity association: service account `spark-history-server` in `spark`

The Spark Operator and YuniKorn do not need AWS IAM roles — they operate entirely within the Kubernetes API.

### Helm (`helm.tf`)

**Spark Operator:**
- Installs the `SparkApplication` and `ScheduledSparkApplication` CRDs
- Webhook enabled for driver/executor pod mutation
- Watches the `spark` namespace by default (configurable)

**YuniKorn:**
- Configured as a secondary scheduler alongside `kube-scheduler`
- Spark jobs opt in by setting `schedulerName: yunikorn` in the `SparkApplication` spec

**Spark History Server:**
- `sparkHistoryOpts` configured to read from `s3a://<var.history_server_bucket>/`
- Service account annotated for Pod Identity

### Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `cluster_name` | string | — | EKS cluster name |
| `cluster_endpoint` | string | — | API server endpoint |
| `cluster_certificate_authority_data` | string | — | Base64 CA cert |
| `history_server_bucket` | string | — | S3 bucket name for Spark history (caller-managed) |
| `history_server_bucket_arn` | string | — | S3 bucket ARN for IAM policy scoping |
| `spark_namespace` | string | `"spark"` | Namespace for Spark jobs |
| `spark_namespace_cpu_limit` | string | `"500"` | ResourceQuota CPU limit for spark namespace |
| `spark_namespace_memory_limit` | string | `"2000Gi"` | ResourceQuota memory limit for spark namespace |
| `tags` | map(string) | `{}` | Tags for AWS resources |

### Outputs

- `spark_history_server_role_arn` — Spark History Server IAM role ARN
- `spark_namespace` — Name of the created Spark namespace

---

## Environment Config Changes

Each `environments/<env>/cluster-1/main.tf` gains two new module calls:

```hcl
module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = "us-east-1"
  grafana_storage_size               = ""        # dev; "20Gi" for prod
  grafana_admin_password             = var.grafana_admin_password

  tags = { Environment = "dev", Team = "data-platform" }
}

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  history_server_bucket              = var.spark_history_bucket
  history_server_bucket_arn          = var.spark_history_bucket_arn

  tags = { Environment = "dev", Team = "data-platform" }
}
```

Sensitive values (`grafana_admin_password`, bucket names) are passed via `terraform.tfvars` (gitignored) or environment variables.

---

## Deploy Order

Same two-phase pattern as the infra layer:

```bash
# Phase 1 — EKS + platform IAM (no Helm providers yet)
terraform apply -target=module.vpc -target=module.eks -target=module.karpenter \
                -target=module.platform.aws_iam_role.lbc \
                -target=module.platform.aws_iam_role.fluentbit \
                -target=module.spark.aws_iam_role.spark_history_server

# Phase 2 — all Helm releases + Kubernetes resources
terraform apply
```

---

## Out of scope

- ArgoCD (GitOps layer — future)
- cert-manager (TLS automation — future)
- Spark job submission patterns and `SparkApplication` examples
- Grafana dashboard provisioning (dashboards-as-code — future)
- Alert routing configuration for Alertmanager
