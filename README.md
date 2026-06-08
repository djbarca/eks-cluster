# EKS Data Platform

Terraform repo for deploying production-grade Amazon EKS clusters across multiple environments (dev, test, prod) in separate AWS accounts. Built for running Apache Spark and internal applications.

---

## What's in this repo

```
modules/
  eks/        # EKS cluster: VPC, IAM, managed node groups, addons, KMS, SSH keys
  karpenter/  # Karpenter autoscaling: IAM, Helm chart, EC2NodeClass, NodePools
  platform/   # Cluster services: AWS LBC, Prometheus/Grafana, Fluent Bit
  spark/      # Data layer: Spark Operator, YuniKorn, Spark History Server
environments/
  dev/cluster-1/
  test/cluster-1/
  prod/cluster-1/
```

Each `environments/<env>/cluster-1/` is an independent Terraform root — separate state, separate AWS account.

---

## Requirements

- Terraform >= 1.9.0
- AWS CLI configured with admin credentials for the target account
- `kubectl` and `helm` for post-deploy cluster access

---

## Deploying a cluster

Fresh deploy requires three phases because Helm/kubectl providers need the cluster endpoint, which doesn't exist until EKS is created.

```bash
cd environments/dev/cluster-1
terraform init

# Phase 1: VPC + EKS cluster (~15 min)
terraform apply -target=module.vpc -target=module.eks

# Phase 2: Karpenter + IAM roles for platform/spark
terraform apply \
  -target=module.karpenter \
  -target=module.platform.aws_iam_role.lbc \
  -target=module.platform.aws_iam_role.fluentbit \
  -target=module.spark.aws_iam_role.spark_history_server

# Phase 3: All Helm releases and Kubernetes resources
terraform apply
```

Subsequent applies on an existing cluster:

```bash
terraform apply
```

---

## Connecting to the cluster

```bash
aws eks update-kubeconfig \
  --name dev-data-platform \
  --region us-east-1

kubectl get nodes
```

---

## Architecture

### Four-layer model

| Layer | Module | What it deploys |
|---|---|---|
| Infra | `modules/eks` | VPC, EKS control plane, managed system node group, EKS addons, KMS keys |
| Autoscaling | `modules/karpenter` | Karpenter controller, EC2NodeClass, `system` and `spark` NodePools |
| Platform | `modules/platform` | AWS Load Balancer Controller†, Prometheus + Grafana†, Fluent Bit → CloudWatch† |
| Data | `modules/spark` | Spark Operator (always on), YuniKorn†, Spark History Server†, spark namespace |

† Conditionally installed — see [Feature flags](#feature-flags).

### Node topology

| Layer | Type | Instances | Purpose |
|---|---|---|---|
| Managed system node group | EKS managed | 2× m6i.large (dev) | Stable foundation for Karpenter + platform pods |
| Karpenter system NodePool | Karpenter-provisioned | m6i.large | General workloads, internal apps |
| Karpenter spark NodePool | Karpenter-provisioned | r6i.large+ (dev), r6i.4xlarge+ (prod) | Spark executors only (taint: `role=spark:NoSchedule`) |

### Key decisions

**Single admin provider:** No role-switching, no permissions boundary. The caller's credentials have admin privileges.

**VPC CNI prefix delegation:** Enabled on all clusters — increases pod density per node from ~10 to ~100+, required for Spark executor density.

**Pod Identity over IRSA:** All addon and controller IAM roles use EKS Pod Identity. No service account annotations needed.

**Karpenter + managed node group coexist:** The managed system node group provides a stable place for Karpenter itself to run. Karpenter owns all other node provisioning.

**`desired_size` ignored by Terraform:** Node groups ignore `desired_size` in state so Karpenter can scale without Terraform fighting it.

**Before-compute addon ordering:** `eks-pod-identity-agent`, `vpc-cni`, and `kube-proxy` install before node groups so nodes come up healthy. vpc-cni uses the node IAM role (not Pod Identity) to avoid a bootstrapping deadlock.

---

## Environment differences

| Setting | dev | test | prod |
|---|---|---|---|
| System node type | m6i.large × 2 | m6i.large × 2 | m6i.xlarge × 3 |
| Spark node types | r6i.large | r6i.large | r6i.4xlarge, r6i.8xlarge |
| NAT gateway | single | single | one per AZ |
| Grafana storage | ephemeral | ephemeral | 20Gi EBS |
| Public API endpoint | yes | yes | no (private only) |

---

## Feature flags

`modules/platform` and `modules/spark` support per-component feature flags (all default `true`). Set to `false` in the environment config to skip a component without removing the module call.

| Module | Variable | Default | Controls |
|---|---|---|---|
| `modules/platform` | `enable_lbc` | `true` | AWS Load Balancer Controller |
| `modules/platform` | `enable_prometheus` | `true` | kube-prometheus-stack (Prometheus + Grafana) |
| `modules/platform` | `enable_fluentbit` | `true` | Fluent Bit → CloudWatch |
| `modules/spark` | `enable_yunikorn` | `true` | YuniKorn gang scheduler |
| `modules/spark` | `enable_history_server` | `true` | Spark History Server |

`enable_history_server = true` also requires `history_server_bucket` and `history_server_bucket_arn` to be set. Both default to `""` and are ignored when the history server is disabled.

---

## Running Spark jobs

Spark jobs are submitted as `SparkApplication` CRDs via the Spark Operator. To use YuniKorn gang scheduling (recommended for production), set `schedulerName: yunikorn` in the spec. Executor pods land on the Karpenter spark NodePool via the `role=spark:NoSchedule` taint.

Spark event logs should be written to the S3 bucket passed as `history_server_bucket` — the Spark History Server reads from there and serves the UI on port 18080.

---

## Operational notes

- **SSH keys in state:** `tls_private_key` writes private keys into Terraform state in plaintext. Use an encrypted S3 backend. Retrieve keys via Secrets Manager (`<cluster>/node-ssh/<group>`).
- **EBS CMK + Auto Scaling:** The `AWSServiceRoleForAutoScaling` SLR must exist in the account. Create it with: `aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com`
- **SSM Session Manager:** Preferred over SSH for node access — no inbound port needed. Node role has `AmazonSSMManagedInstanceCore` attached.
- **State backend:** S3 backend not yet configured. Add a `backend "s3"` block to each environment's `versions.tf` before deploying to production.
