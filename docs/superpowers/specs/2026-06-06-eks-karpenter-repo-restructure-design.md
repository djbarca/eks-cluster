# EKS + Karpenter Repo Restructure Design

**Date:** 2026-06-06
**Status:** Approved

---

## Context

This repo is used by a single team to deploy EKS clusters across multiple environments (dev, test, prod) in separate AWS accounts. Some environments may run more than one cluster. The eventual goal is to run Apache Spark and internal applications on these clusters.

The current repo has the EKS module at the root with a throwaway `examples/complete/` directory. This design formalises the structure for long-term maintenance.

---

## Repository Structure

```
eks-cluster/
├── modules/
│   ├── eks/                        # core cluster module (moved from root)
│   │   ├── main.tf
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── cluster.tf
│   │   ├── node_groups.tf
│   │   ├── addons.tf
│   │   ├── kms.tf
│   │   ├── ssh_keys.tf
│   │   └── access_entries.tf
│   └── karpenter/                  # new module
│       ├── main.tf
│       ├── versions.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── iam.tf
│       └── helm.tf
├── environments/
│   ├── dev/
│   │   └── cluster-1/
│   │       ├── main.tf             # calls modules/eks + modules/karpenter
│   │       └── versions.tf
│   ├── test/
│   │   └── cluster-1/
│   └── prod/
│       └── cluster-1/
└── CLAUDE.md
```

### Key decisions

- Each `environments/<env>/<cluster>/` is an independent Terraform root with its own state. Adding a second cluster in any environment is a new directory — no shared state to untangle.
- `examples/` is removed. `environments/dev/cluster-1/` is the real deployment.
- State backend (S3) is deferred — `versions.tf` in each environment has provider constraints only, no backend block for now.

---

## Module: `modules/eks/`

**What changes:** files move from the repo root to `modules/eks/`. No logic changes.

**One addition:** `enable_prefix_delegation` variable. When `true`, passes a `configuration_values` JSON blob to the `vpc-cni` addon enabling prefix delegation. This increases pod capacity per node from ~10 to ~100+, which is required for Spark executor density.

**Outputs required by the Karpenter module:**

| Output | Used for |
|---|---|
| `cluster_name` | Karpenter helm values + EC2NodeClass |
| `cluster_endpoint` | Karpenter helm values |
| `cluster_certificate_authority_data` | Karpenter helm values |
| `cluster_security_group_id` | EC2NodeClass security group |
| `node_iam_role_name` | Karpenter node access entry + EC2NodeClass |

All already exist in `outputs.tf` except `node_iam_role_name` — add it.

---

## Module: `modules/karpenter/`

### Inputs

| Variable | Type | Description |
|---|---|---|
| `cluster_name` | string | EKS cluster name |
| `cluster_endpoint` | string | API server endpoint |
| `cluster_certificate_authority_data` | string | Base64 CA cert |
| `node_iam_role_name` | string | Node IAM role name (reused by Karpenter nodes) |
| `subnet_ids` | list(string) | Subnets for Karpenter-provisioned nodes |
| `security_group_ids` | list(string) | Security groups for Karpenter-provisioned nodes |
| `karpenter_version` | string | Helm chart version (default: latest at deploy time via data source) |
| `node_pools` | map(object) | NodePool definitions (see below) |
| `tags` | map(string) | Tags applied to all resources |

### `node_pools` object shape

```hcl
node_pools = {
  system = {
    instance_types     = ["m6i.large"]
    capacity_type      = "on-demand"       # on-demand | spot
    labels             = { role = "system" }
    taints             = []
    min_size           = 0
    max_size           = 10
  }
  spark = {
    instance_types     = ["r6i.2xlarge", "r6i.4xlarge"]
    capacity_type      = "on-demand"
    labels             = { role = "spark" }
    taints             = [{ key = "role", value = "spark", effect = "NoSchedule" }]
    min_size           = 0
    max_size           = 50
  }
}
```

All instance types in the module will be on-demand (per requirements). `capacity_type` is included in the variable for completeness but defaults to `on-demand`.

### Resources created

**`iam.tf`**
- `aws_iam_role` — Karpenter controller role, trusts `pods.eks.amazonaws.com` (Pod Identity)
- `aws_iam_role_policy_attachment` — attaches `AmazonEKSWorkerNodePolicy` + inline policy for EC2/SQS/EKS actions Karpenter needs
- `aws_eks_access_entry` — registers the node IAM role so Karpenter-launched nodes can join the cluster

**`helm.tf`**
- `helm_release` — Karpenter controller chart, configured with Pod Identity service account annotation
- `kubectl_manifest` (one `EC2NodeClass`) — shared across all NodePools; uses AL2023 AMI family, references subnet/SG IDs
- `kubectl_manifest` (one `NodePool` per entry in `var.node_pools`) — references the shared EC2NodeClass; sets instance types, labels, taints, and capacity limits

### Provider requirements

The Karpenter module requires three providers:
- `hashicorp/aws ~> 6.0`
- `hashicorp/helm ~> 2.0`
- `gavinbunney/kubectl ~> 1.0` — for applying `EC2NodeClass` and `NodePool` CRDs

These are declared as `configuration_aliases` in `versions.tf` and passed in from the environment config.

---

## Environment Config: `environments/dev/cluster-1/`

```hcl
# main.tf

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"
  # ... standard VPC config
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name             = "dev-data-platform"
  kubernetes_version       = "1.36"
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  enable_prefix_delegation = true

  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      desired_size   = 2
      min_size       = 2
      max_size       = 4
      labels         = { role = "system" }
    }
  }

  cluster_addons = { ... }

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}

module "karpenter" {
  source = "../../../modules/karpenter"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  node_iam_role_name                 = module.eks.node_iam_role_name
  subnet_ids                         = module.vpc.private_subnets
  security_group_ids                 = [module.eks.cluster_security_group_id]

  node_pools = {
    system = {
      instance_types = ["m6i.large"]
      labels         = { role = "system" }
      taints         = []
    }
    spark = {
      instance_types = ["r6i.2xlarge", "r6i.4xlarge"]
      labels         = { role = "spark" }
      taints         = [{ key = "role", value = "spark", effect = "NoSchedule" }]
    }
  }

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}
```

### System node group rationale

The managed `system` node group is kept alongside Karpenter. Karpenter itself must run somewhere before it can provision nodes — the system node group provides that stable foundation. Platform components (CoreDNS, vpc-cni, kube-proxy, Karpenter controller) are scheduled here. Karpenter manages everything else.

### Environment differences (dev vs prod)

| Config | dev | prod |
|---|---|---|
| System node `instance_types` | `m6i.large` | `m6i.xlarge` |
| System node `min_size` | 2 | 3 |
| Spark `instance_types` | `r6i.2xlarge` | `r6i.4xlarge`, `r6i.8xlarge` |
| `single_nat_gateway` | `true` | `false` |

---

## Out of scope (future)

- S3 remote state backend
- Platform layer: ArgoCD, Prometheus/Grafana, AWS LB Controller, cert-manager, Fluent Bit
- Data layer: Spark Operator, YuniKorn, Spark History Server, JupyterHub
