# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Terraform repo that deploys production-grade Amazon EKS clusters with Karpenter autoscaling across multiple environments (dev, test, prod) in separate AWS accounts.

## Versions

- Terraform: `>= 1.9.0` (latest stable: 1.15.5)
- AWS provider: `~> 6.0` (latest: 6.49.0)
- TLS provider: `~> 4.0`
- Helm provider: `~> 2.0`
- kubectl provider: `alekc/kubectl ~> 2.0`
- VPC module: `~> 6.0` (latest: 6.6.1)
- Karpenter Helm chart: `1.10.0`

## Commands

```bash
# Validate and format (run from repo root)
terraform fmt -recursive
terraform -chdir=modules/eks validate
terraform -chdir=modules/karpenter validate
terraform -chdir=modules/platform validate
terraform -chdir=modules/spark validate

# Deploy a cluster (fresh — three phases because Helm/kubectl providers need
# the cluster endpoint, which is unknown until EKS exists)
terraform -chdir=environments/dev/cluster-1 init

# Phase 1: VPC + EKS cluster
terraform -chdir=environments/dev/cluster-1 apply -target=module.vpc -target=module.eks

# Phase 2: Karpenter + platform/spark IAM roles (no Helm yet)
# Omit targets for disabled components (e.g. skip spark_history_server if enable_history_server=false)
terraform -chdir=environments/dev/cluster-1 apply \
  -target=module.karpenter \
  -target=module.platform.aws_iam_role.lbc \
  -target=module.platform.aws_iam_role.fluentbit \
  -target=module.spark.aws_iam_role.spark_history_server

# Phase 3: All Helm releases and Kubernetes resources
terraform -chdir=environments/dev/cluster-1 apply

# Subsequent applies (cluster already exists) — single apply works
terraform -chdir=environments/dev/cluster-1 apply
```

## Repository Structure

```
modules/
  eks/          # Core EKS cluster: VPC, IAM, cluster, node groups, addons, KMS, SSH keys
  karpenter/    # Karpenter controller: IAM, Helm chart, EC2NodeClass, NodePools
  platform/     # Cluster services: AWS LBC, kube-prometheus-stack, Fluent Bit → CloudWatch
  spark/        # Data layer: Spark Operator, YuniKorn, Spark History Server, spark namespace
environments/
  dev/cluster-1/    # Dev deployment (m6i.large system nodes, r6i.large spark)
  test/cluster-1/   # Test deployment (same shape as dev, separate account)
  prod/cluster-1/   # Prod deployment (m6i.xlarge system, r6i.4xlarge+ spark, multi-AZ NAT)
```

## Architecture

Each `environments/<env>/<cluster>/` is an independent Terraform root with its own state. The environment config calls all four modules and wires them together: `modules/eks` → `modules/karpenter` → `modules/platform` → `modules/spark`.

### Key design decisions

**Single AWS provider (admin role):** No provider aliases, no permissions boundary, no role-switching. The role running Terraform has admin privileges.

**Karpenter alongside a managed system node group:** The system node group (2–3 `m6i.large/xlarge` nodes) provides a stable foundation for Karpenter and platform components. Karpenter provisions all other nodes dynamically.

**VPC CNI prefix delegation:** `enable_prefix_delegation = true` on all clusters — increases pod capacity per node from ~10 to ~100+, required for Spark executor density.

**`desired_size` under `ignore_changes`:** Node groups ignore `desired_size` so Karpenter can own scaling without Terraform reverting it.

**bootstrap_cluster_creator_admin_permissions = false:** Cluster access is always explicit via access entries. The `grant_developer_admin` variable (default `true`) creates an access entry for the caller using `data.aws_iam_role` to resolve SSO role paths correctly.

**Before-compute addons:** `eks-pod-identity-agent`, `vpc-cni`, `kube-proxy` all have `before_compute = true`. Node groups depend on `aws_eks_addon.before_compute` to ensure CNI is ready when nodes join. vpc-cni uses the node IAM role (not Pod Identity) to avoid a bootstrapping deadlock.

**KMS service-principal grants:** CloudWatch and EC2 service principals are not covered by root-account IAM delegation. Key policies grant them explicitly. The EBS key also grants `AWSServiceRoleForAutoScaling`.

**SSH private keys in state:** `tls_private_key` writes private keys into Terraform state in plaintext. Use an encrypted, access-restricted remote state backend (S3 with SSE). Secrets Manager (`store_ssh_keys_in_secrets_manager = true`, default) is the safer retrieval path.

**Feature flags:** `modules/platform` and `modules/spark` have per-component boolean flags (all default `true`). Set to `false` to skip installing a component without removing the module call.

| Module | Variable | Controls |
|---|---|---|
| `modules/platform` | `enable_lbc` | AWS Load Balancer Controller |
| `modules/platform` | `enable_prometheus` | kube-prometheus-stack |
| `modules/platform` | `enable_fluentbit` | Fluent Bit → CloudWatch |
| `modules/spark` | `enable_yunikorn` | YuniKorn gang scheduler |
| `modules/spark` | `enable_history_server` | Spark History Server (also requires `history_server_bucket` + `history_server_bucket_arn` when enabled) |
| `modules/spark` | `job_data_bucket_arns` | List of S3 bucket ARNs. When non-empty, creates an IAM role with R/W access bound to the `spark` SA via Pod Identity. Driver/executors get these creds automatically. |

## Spark job examples

`examples/spark-jobs/` contains working `SparkApplication` manifests:

- `spark-sa.yaml` — one-time `spark` ServiceAccount + RBAC the operator needs
- `pi-job.yaml` — SparkPi smoke test (no S3, validates operator + Karpenter)
- `s3-wordcount-job.yaml` — validates Pod Identity → S3A read + event log write

### Spark image gotchas

- `apache/spark:3.5.3` does not ship `hadoop-aws` or `aws-java-sdk-bundle`. The example jobs and the History Server use an `initContainer` to download both jars into a shared `emptyDir` and pick them up via `SPARK_DIST_CLASSPATH` / `spark.{driver,executor}.extraClassPath`. Bake these jars into a custom image to avoid the per-pod download.
- **`aws-java-sdk-bundle` must be ≥ 1.12.367** (this repo uses 1.12.788). Earlier versions reject EKS Pod Identity's `169.254.170.23` credential endpoint with `"Host can only be one of [localhost, 127.0.0.1]"`.
- **S3A credential provider must be `org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider`** for Pod Identity. The default chain checks env vars first and fails before reaching the container creds.
- **`spark.eventLog.dir` requires a path segment** (e.g. `s3a://bucket/logs`, not `s3a://bucket/`). S3A treats the bucket-only form as non-absolute and crashes during `SparkContext` init.
