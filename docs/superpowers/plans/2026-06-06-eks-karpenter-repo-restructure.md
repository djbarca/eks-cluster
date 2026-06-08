# EKS + Karpenter Repo Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the repo so the EKS module lives in `modules/eks/`, add a `modules/karpenter/` module, and wire them together in `environments/dev/cluster-1/`.

**Architecture:** The EKS module files move from the repo root to `modules/eks/` unchanged (plus two small additions). A new `modules/karpenter/` module provisions the Karpenter controller IAM role, Helm chart, and Karpenter NodePools + EC2NodeClass CRs. The `environments/dev/cluster-1/` root calls both modules.

**Tech Stack:** Terraform >= 1.9, AWS provider ~> 6.0, Helm provider ~> 2.0, alekc/kubectl provider ~> 2.0, Karpenter Helm chart 1.10.0 (from OCI ECR public registry).

---

## File Map

### Created
- `modules/eks/` — all current root `*.tf` files moved here (no logic changes)
- `modules/karpenter/versions.tf` — provider requirements
- `modules/karpenter/variables.tf` — all inputs
- `modules/karpenter/main.tf` — locals + Pod Identity association
- `modules/karpenter/iam.tf` — controller IAM role + node access entry
- `modules/karpenter/helm.tf` — Helm release + EC2NodeClass + NodePool CRs
- `modules/karpenter/outputs.tf` — controller role ARN
- `environments/dev/cluster-1/versions.tf` — provider + terraform constraints
- `environments/dev/cluster-1/main.tf` — VPC + EKS + Karpenter wiring
- `environments/test/cluster-1/versions.tf` — stub (same as dev)
- `environments/test/cluster-1/main.tf` — stub (copy of dev, different values)
- `environments/prod/cluster-1/versions.tf` — stub (same as dev)
- `environments/prod/cluster-1/main.tf` — stub (copy of dev, larger instances)

### Modified
- `modules/eks/variables.tf` — add `enable_prefix_delegation`
- `modules/eks/addons.tf` — use `enable_prefix_delegation` for vpc-cni config
- `modules/eks/outputs.tf` — add `node_iam_role_name`

### Deleted
- `examples/` — replaced by `environments/dev/cluster-1/`

---

### Task 1: Move EKS module files to `modules/eks/`

**Files:**
- Create dir: `modules/eks/`
- Move: all `*.tf` at repo root → `modules/eks/`

- [ ] **Step 1: Create directory and move files**

```bash
mkdir -p modules/eks
mv access_entries.tf addons.tf cluster.tf kms.tf main.tf \
   node_groups.tf outputs.tf ssh_keys.tf variables.tf versions.tf \
   modules/eks/
```

- [ ] **Step 2: Validate the module still parses**

```bash
cd modules/eks && terraform init -backend=false 2>&1 | tail -5
```

Expected: `Terraform has been successfully initialized!`

- [ ] **Step 3: Commit**

```bash
git add modules/eks/ access_entries.tf addons.tf cluster.tf kms.tf \
        main.tf node_groups.tf outputs.tf ssh_keys.tf variables.tf versions.tf
git commit -m "refactor: move EKS module files to modules/eks/"
```

---

### Task 2: Add `enable_prefix_delegation` to the EKS module

**Files:**
- Modify: `modules/eks/variables.tf`
- Modify: `modules/eks/addons.tf`

- [ ] **Step 1: Add variable to `modules/eks/variables.tf`**

Add this block at the end of the `###  Networking ###` section (after `public_access_cidrs`):

```hcl
variable "enable_prefix_delegation" {
  description = "Enable VPC CNI prefix delegation to increase pod density per node. Recommended when running Spark workloads."
  type        = bool
  default     = false
}
```

- [ ] **Step 2: Wire prefix delegation into the vpc-cni addon config in `modules/eks/addons.tf`**

Find the `resolved_addon_version` local in `addons.tf`. Directly below it, add:

```hcl
locals {
  vpc_cni_configuration_values = var.enable_prefix_delegation ? jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  }) : null
}
```

- [ ] **Step 3: Use the local when building before_compute addons**

In `aws_eks_addon.before_compute`, the `configuration_values` line currently reads:

```hcl
configuration_values = each.value.configuration_values
```

Change it to:

```hcl
configuration_values = each.key == "vpc-cni" && local.vpc_cni_configuration_values != null ? local.vpc_cni_configuration_values : each.value.configuration_values
```

- [ ] **Step 4: Validate**

```bash
cd modules/eks && terraform validate 2>&1
```

Expected: `Success! The configuration is valid`

- [ ] **Step 5: Commit**

```bash
git add modules/eks/variables.tf modules/eks/addons.tf
git commit -m "feat(eks): add enable_prefix_delegation variable for vpc-cni"
```

---

### Task 3: Add `node_iam_role_name` output to the EKS module

**Files:**
- Modify: `modules/eks/outputs.tf`

- [ ] **Step 1: Add output**

Append to `modules/eks/outputs.tf`:

```hcl
output "node_iam_role_name" {
  description = "Name of the shared IAM role for managed node groups (used by Karpenter for node access entry)."
  value       = try(aws_iam_role.node[0].name, null)
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/eks/outputs.tf
git commit -m "feat(eks): expose node_iam_role_name output"
```

---

### Task 4: Create `modules/karpenter/versions.tf`

**Files:**
- Create: `modules/karpenter/versions.tf`

- [ ] **Step 1: Write the file**

```hcl
terraform {
  required_version = ">= 1.9.0"
}
```

Note: `required_providers` is intentionally omitted from module `versions.tf` — provider schemas are loaded from the calling root configuration, avoiding the Terraform 1.15 module-init deadlock (same pattern used in `modules/eks/versions.tf`).

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/versions.tf
git commit -m "feat(karpenter): add versions.tf"
```

---

### Task 5: Create `modules/karpenter/variables.tf`

**Files:**
- Create: `modules/karpenter/variables.tf`

- [ ] **Step 1: Write the file**

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

variable "node_iam_role_name" {
  description = "Name of the existing node IAM role. Karpenter-launched nodes reuse this role."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs where Karpenter may provision nodes."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs attached to Karpenter-provisioned nodes."
  type        = list(string)
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version. Defaults to 1.10.0."
  type        = string
  default     = "1.10.0"
}

variable "karpenter_namespace" {
  description = "Kubernetes namespace to deploy Karpenter into."
  type        = string
  default     = "karpenter"
}

variable "node_pools" {
  description = <<-EOT
    Map of Karpenter NodePools to create. Each entry produces one NodePool and
    shares the single EC2NodeClass. Example:

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
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "on-demand")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    min_size = optional(number, 0)
    max_size = optional(number, 50)
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to all taggable AWS resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/variables.tf
git commit -m "feat(karpenter): add variables.tf"
```

---

### Task 6: Create `modules/karpenter/main.tf`

**Files:**
- Create: `modules/karpenter/main.tf`

- [ ] **Step 1: Write the file**

```hcl
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
}

# Pod Identity association: links the karpenter service account (created by
# the Helm chart) to the controller IAM role. AWS delivers credentials to
# Karpenter pods without any service account annotation needed.
resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = var.karpenter_namespace
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/main.tf
git commit -m "feat(karpenter): add main.tf with Pod Identity association"
```

---

### Task 7: Create `modules/karpenter/iam.tf`

**Files:**
- Create: `modules/karpenter/iam.tf`

- [ ] **Step 1: Write the file**

```hcl
###############################################################################
# Karpenter controller IAM role (Pod Identity)
###############################################################################

data "aws_iam_policy_document" "karpenter_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume.json

  tags = merge(var.tags, {
    Name         = "${var.cluster_name}-karpenter-controller"
    role-purpose = "karpenter-controller"
  })
}

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 instance management
  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  # Pass the node IAM role to EC2 instances
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.node_iam_role_name}"]
  }

  # Instance profile management (required for Karpenter v1.x)
  statement {
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["*"]
  }

  # EKS cluster info
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"]
  }

  # Spot price history for bin-packing decisions
  statement {
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name   = "${var.cluster_name}-karpenter-controller"
  policy = data.aws_iam_policy_document.karpenter_controller.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

###############################################################################
# Node access entry — allows Karpenter-launched nodes to join the cluster.
# The node IAM role already exists (created by modules/eks); we just need to
# register it as an EKS access entry so the nodes are trusted.
###############################################################################

resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = var.cluster_name
  principal_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.node_iam_role_name}"
  type          = "EC2_LINUX"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-karpenter-node-entry"
  })
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/iam.tf
git commit -m "feat(karpenter): add IAM role and node access entry"
```

---

### Task 8: Create `modules/karpenter/helm.tf`

**Files:**
- Create: `modules/karpenter/helm.tf`

- [ ] **Step 1: Write the file**

```hcl
###############################################################################
# Karpenter Helm chart
###############################################################################

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = var.karpenter_namespace
  create_namespace = true

  values = [yamlencode({
    settings = {
      clusterName = var.cluster_name
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
    serviceAccount = {
      name = "karpenter"
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.karpenter,
    aws_eks_access_entry.karpenter_nodes,
  ]
}

###############################################################################
# EC2NodeClass — shared by all NodePools; defines the AMI family, subnets,
# security groups, and node IAM role for Karpenter-launched instances.
###############################################################################

resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      role             = var.node_iam_role_name
      subnetSelectorTerms = [
        for id in var.subnet_ids : { id = id }
      ]
      securityGroupSelectorTerms = [
        for id in var.security_group_ids : { id = id }
      ]
      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
      })
    }
  })

  depends_on = [helm_release.karpenter]
}

###############################################################################
# NodePools — one per entry in var.node_pools
###############################################################################

resource "kubectl_manifest" "nodepool" {
  for_each = var.node_pools

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = each.key
    }
    spec = {
      template = {
        metadata = {
          labels = each.value.labels
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = concat(
            [
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = [each.value.capacity_type]
              },
              {
                key      = "node.kubernetes.io/instance-type"
                operator = "In"
                values   = each.value.instance_types
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
            ],
            [for t in each.value.taints : {
              key      = t.key
              operator = "Exists"
              effect   = t.effect
            }]
          )
          taints = [
            for t in each.value.taints : {
              key    = t.key
              value  = t.value
              effect = t.effect
            }
          ]
        }
      }
      limits = {
        cpu    = "1000"
        memory = "1000Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/helm.tf
git commit -m "feat(karpenter): add Helm release, EC2NodeClass, and NodePool resources"
```

---

### Task 9: Create `modules/karpenter/outputs.tf`

**Files:**
- Create: `modules/karpenter/outputs.tf`

- [ ] **Step 1: Write the file**

```hcl
output "controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role."
  value       = aws_iam_role.karpenter_controller.arn
}

output "controller_role_name" {
  description = "Name of the Karpenter controller IAM role."
  value       = aws_iam_role.karpenter_controller.name
}
```

- [ ] **Step 2: Commit**

```bash
git add modules/karpenter/outputs.tf
git commit -m "feat(karpenter): add outputs.tf"
```

---

### Task 10: Create `environments/dev/cluster-1/`

**Files:**
- Create: `environments/dev/cluster-1/versions.tf`
- Create: `environments/dev/cluster-1/main.tf`

- [ ] **Step 1: Create `environments/dev/cluster-1/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "tls" {}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
  }
}
```

- [ ] **Step 2: Create `environments/dev/cluster-1/main.tf`**

```hcl
locals {
  cluster_name = "dev-data-platform"
  vpc_cidr     = "10.0.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"    = 1
    "karpenter.sh/discovery"             = local.cluster_name
  }

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}

###############################################################################
# EKS cluster
###############################################################################

module "eks" {
  source = "../../../modules/eks"

  cluster_name       = local.cluster_name
  kubernetes_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access   = true
  endpoint_private_access  = true
  public_access_cidrs      = ["0.0.0.0/0"] # lock to your IP in production

  enable_prefix_delegation = true

  ssh_ingress_cidrs = ["10.0.0.0/8"]

  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      desired_size   = 2
      min_size       = 2
      max_size       = 4
      disk_size_gib  = 80
      labels         = { role = "system" }
    }
  }

  cluster_addons = {
    eks-pod-identity-agent = {
      before_compute = true
    }
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {
      before_compute = true
    }
    coredns = {}
    aws-ebs-csi-driver = {
      pod_identity    = true
      service_account = "ebs-csi-controller-sa"
      policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
  }

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}

###############################################################################
# Karpenter
###############################################################################

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
      max_size       = 10
    }
    spark = {
      instance_types = ["r6i.2xlarge", "r6i.4xlarge"]
      labels         = { role = "spark" }
      taints = [{
        key    = "role"
        value  = "spark"
        effect = "NoSchedule"
      }]
      max_size = 50
    }
  }

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add environments/dev/cluster-1/
git commit -m "feat(environments): add dev/cluster-1 environment"
```

---

### Task 11: Create `environments/test/` and `environments/prod/` stubs

**Files:**
- Create: `environments/test/cluster-1/versions.tf`
- Create: `environments/test/cluster-1/main.tf`
- Create: `environments/prod/cluster-1/versions.tf`
- Create: `environments/prod/cluster-1/main.tf`

- [ ] **Step 1: Create test environment (copy of dev, different cluster name)**

`environments/test/cluster-1/versions.tf` — identical to dev `versions.tf` with `cluster_name` swapped in the exec args:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "tls" {}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
  }
}
```

`environments/test/cluster-1/main.tf`:

```hcl
locals {
  cluster_name = "test-data-platform"
  vpc_cidr     = "10.1.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = { Environment = "test", Team = "data-platform" }
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name             = local.cluster_name
  kubernetes_version       = "1.36"
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  endpoint_public_access   = true
  endpoint_private_access  = true
  public_access_cidrs      = ["0.0.0.0/0"]
  enable_prefix_delegation = true
  ssh_ingress_cidrs        = ["10.0.0.0/8"]

  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      desired_size   = 2
      min_size       = 2
      max_size       = 4
      disk_size_gib  = 80
      labels         = { role = "system" }
    }
  }

  cluster_addons = {
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
    kube-proxy             = { before_compute = true }
    coredns                = {}
    aws-ebs-csi-driver = {
      pod_identity    = true
      service_account = "ebs-csi-controller-sa"
      policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
  }

  tags = { Environment = "test", Team = "data-platform" }
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
      max_size       = 10
    }
    spark = {
      instance_types = ["r6i.2xlarge", "r6i.4xlarge"]
      labels         = { role = "spark" }
      taints         = [{ key = "role", value = "spark", effect = "NoSchedule" }]
      max_size       = 50
    }
  }

  tags = { Environment = "test", Team = "data-platform" }
}
```

- [ ] **Step 2: Create prod environment (larger instances, multi-AZ NAT)**

`environments/prod/cluster-1/versions.tf` — identical to test `versions.tf`, update `local.cluster_name` reference in exec args.

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "tls" {}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
  }
}
```

`environments/prod/cluster-1/main.tf`:

```hcl
locals {
  cluster_name = "prod-data-platform"
  vpc_cidr     = "10.2.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = false # one NAT per AZ in production
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = { Environment = "prod", Team = "data-platform" }
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name             = local.cluster_name
  kubernetes_version       = "1.36"
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  endpoint_public_access   = false
  endpoint_private_access  = true
  enable_prefix_delegation = true

  node_groups = {
    system = {
      instance_types = ["m6i.xlarge"]
      ami_type       = "AL2023_x86_64_STANDARD"
      desired_size   = 3
      min_size       = 3
      max_size       = 6
      disk_size_gib  = 100
      labels         = { role = "system" }
    }
  }

  cluster_addons = {
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
    kube-proxy             = { before_compute = true }
    coredns                = {}
    aws-ebs-csi-driver = {
      pod_identity    = true
      service_account = "ebs-csi-controller-sa"
      policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
  }

  tags = { Environment = "prod", Team = "data-platform" }
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
      instance_types = ["m6i.xlarge"]
      labels         = { role = "system" }
      taints         = []
      max_size       = 10
    }
    spark = {
      instance_types = ["r6i.4xlarge", "r6i.8xlarge"]
      labels         = { role = "spark" }
      taints         = [{ key = "role", value = "spark", effect = "NoSchedule" }]
      max_size       = 100
    }
  }

  tags = { Environment = "prod", Team = "data-platform" }
}
```

- [ ] **Step 3: Commit**

```bash
git add environments/test/ environments/prod/
git commit -m "feat(environments): add test and prod cluster stubs"
```

---

### Task 12: Remove `examples/` directory

**Files:**
- Delete: `examples/`

- [ ] **Step 1: Remove the examples directory**

```bash
git rm -r examples/
git commit -m "chore: remove examples/ — replaced by environments/dev/cluster-1/"
```

---

### Task 13: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the CLAUDE.md content**

Replace the existing CLAUDE.md with:

```markdown
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

# Deploy dev cluster
terraform -chdir=environments/dev/cluster-1 init
terraform -chdir=environments/dev/cluster-1 plan
terraform -chdir=environments/dev/cluster-1 apply
```

## Repository Structure

```
modules/
  eks/          # Core EKS cluster: VPC, IAM, cluster, node groups, addons, KMS, SSH keys
  karpenter/    # Karpenter controller: IAM, Helm chart, EC2NodeClass, NodePools
environments/
  dev/cluster-1/    # Dev deployment (m6i.large system nodes, r6i.2xlarge spark)
  test/cluster-1/   # Test deployment (same shape as dev, separate account)
  prod/cluster-1/   # Prod deployment (m6i.xlarge system, r6i.4xlarge+ spark, multi-AZ NAT)
```

## Architecture

Each `environments/<env>/<cluster>/` is an independent Terraform root with its own state. The environment config calls `modules/eks` and `modules/karpenter` and wires them together.

### Key design decisions

**Single AWS provider (admin role):** No provider aliases, no permissions boundary, no role-switching. The role running Terraform has admin privileges.

**Karpenter alongside a managed system node group:** The system node group (2–3 `m6i.large/xlarge` nodes) provides a stable foundation for Karpenter and platform components. Karpenter provisions all other nodes dynamically.

**VPC CNI prefix delegation:** `enable_prefix_delegation = true` on all clusters — increases pod capacity per node from ~10 to ~100+, required for Spark executor density.

**`desired_size` under `ignore_changes`:** Node groups ignore `desired_size` so Karpenter can own scaling without Terraform reverting it.

**bootstrap_cluster_creator_admin_permissions = false:** Cluster access is always explicit via access entries. The `grant_developer_admin` variable (default `true`) creates an access entry for the caller using `data.aws_iam_role` to resolve SSO role paths correctly.

**Before-compute addons:** `eks-pod-identity-agent`, `vpc-cni`, `kube-proxy` all have `before_compute = true`. Node groups depend on `aws_eks_addon.before_compute` to ensure CNI is ready when nodes join. vpc-cni uses the node IAM role (not Pod Identity) to avoid a bootstrapping deadlock.

**KMS service-principal grants:** CloudWatch and EC2 service principals are not covered by root-account IAM delegation. Key policies grant them explicitly. The EBS key also grants `AWSServiceRoleForAutoScaling`.

**SSH private keys in state:** `tls_private_key` writes private keys into Terraform state in plaintext. Use an encrypted, access-restricted remote state backend (S3 with SSE). Secrets Manager (`store_ssh_keys_in_secrets_manager = true`, default) is the safer retrieval path.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for new repo structure"
```

---

### Task 14: Init and validate all roots

- [ ] **Step 1: Validate `modules/eks/`**

```bash
cd modules/eks && terraform init -backend=false && terraform validate
```

Expected: `Success! The configuration is valid`

- [ ] **Step 2: Validate `modules/karpenter/`**

```bash
cd modules/karpenter && terraform init -backend=false && terraform validate
```

Expected: `Success! The configuration is valid`

- [ ] **Step 3: Init `environments/dev/cluster-1/`**

```bash
cd environments/dev/cluster-1 && terraform init
```

Expected: modules download, providers install, `Terraform has been successfully initialized!`

- [ ] **Step 4: Validate `environments/dev/cluster-1/`**

```bash
terraform validate
```

Expected: `Success! The configuration is valid`

- [ ] **Step 5: Final commit**

```bash
git add .
git commit -m "chore: verified all terraform roots init and validate"
```
