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
| `modules/spark` | `job_data_bucket_arns` | `[]` | S3 bucket ARNs for Spark job R/W access via Pod Identity |

`enable_history_server = true` also requires `history_server_bucket` and `history_server_bucket_arn`. Both default to `""` and are ignored when the history server is disabled.

`job_data_bucket_arns` controls a separate IAM role bound to the `spark` ServiceAccount via Pod Identity. When non-empty, the driver and executor pods automatically receive credentials with R/W access to each bucket. Include the History Server bucket in this list if jobs need to write event logs.

---

## Running Spark jobs

Spark jobs are submitted as `SparkApplication` CRDs via the Spark Operator. Executor pods land on the Karpenter spark NodePool via the `role=spark:NoSchedule` taint.

### One-time setup

Apply the `spark` ServiceAccount and RBAC the operator needs:

```bash
kubectl apply -f examples/spark-jobs/spark-sa.yaml
```

### SparkPi smoke test (no S3 required)

```bash
kubectl apply -f examples/spark-jobs/pi-job.yaml
kubectl get sparkapplication -n spark spark-pi -w
kubectl logs -n spark spark-pi-driver | grep "Pi is roughly"
```

Expect ~3 minutes — Karpenter provisions a spark node, the driver and 2 executors run, Pi prints.

### S3 read/write job

This validates Pod Identity → S3A, including event-log writes to the History Server bucket.

```bash
# Upload sample input
echo -e "the quick brown fox\nthe lazy dog\nthe quick fox" > /tmp/words.txt
aws s3 cp /tmp/words.txt s3://<your-data-bucket>/input/words.txt

# Edit s3-wordcount-job.yaml to point at your buckets, then:
kubectl apply -f examples/spark-jobs/s3-wordcount-job.yaml
kubectl logs -n spark s3-wordcount-driver -f

# View it in the History Server UI
kubectl port-forward -n spark svc/spark-history-server 18080:18080 &
open http://localhost:18080
```

### Spark image gotchas

The `apache/spark:3.5.3` image does NOT ship the S3A jars. The example jobs and the History Server work around this with an `initContainer` that downloads `hadoop-aws` and `aws-java-sdk-bundle` into a shared volume on every pod start. For production, **bake a custom image** with these jars pre-installed — saves ~15s per pod and removes the Maven Central dependency.

The job manifests pin specific versions for known-working Pod Identity support:
- `hadoop-aws:3.3.4` (matches Spark 3.5.x's hadoop-client)
- `aws-java-sdk-bundle:1.12.788` — earlier versions reject Pod Identity's link-local credential endpoint

The driver/executor `sparkConf` includes two non-obvious entries:
- `spark.hadoop.fs.s3a.aws.credentials.provider = org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider` — bypasses the default chain that checks env vars first
- `spark.eventLog.dir = s3a://bucket/logs` — never bare `s3a://bucket/` (S3A treats it as non-absolute and crashes)

### YuniKorn gang scheduling

Add `schedulerName: yunikorn` to the `driver` and `executor` specs in your `SparkApplication`. Critical for production jobs with many executors — guarantees all-or-nothing scheduling so partial allocations don't waste Karpenter capacity.

---

## Operational notes

- **SSH keys in state:** `tls_private_key` writes private keys into Terraform state in plaintext. Use an encrypted S3 backend. Retrieve keys via Secrets Manager (`<cluster>/node-ssh/<group>`).
- **EBS CMK + Auto Scaling:** The `AWSServiceRoleForAutoScaling` SLR must exist in the account. Create it with: `aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com`
- **SSM Session Manager:** Preferred over SSH for node access — no inbound port needed. Node role has `AmazonSSMManagedInstanceCore` attached.
- **State backend:** S3 backend not yet configured. Add a `backend "s3"` block to each environment's `versions.tf` before deploying to production.
