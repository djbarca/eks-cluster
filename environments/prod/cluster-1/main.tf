locals {
  cluster_name = "prod-data-platform"
  vpc_cidr     = "10.2.0.0/16"
  aws_region   = "us-east-1"
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
  single_nat_gateway   = false
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

  depends_on = [module.eks]
}

###############################################################################
# Platform
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = local.aws_region
  grafana_storage_size               = "20Gi"
  grafana_admin_password             = var.grafana_admin_password

  tags = { Environment = "prod", Team = "data-platform" }

  depends_on = [module.eks]
}

###############################################################################
# Spark
###############################################################################

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  tags = { Environment = "prod", Team = "data-platform" }

  depends_on = [module.platform]
}
