locals {
  cluster_name = "dev-data-platform"
  vpc_cidr     = "10.0.0.0/16"
  aws_region   = "us-east-1"
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
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
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

  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = ["0.0.0.0/0"]

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
    coredns                   = {}
    metrics-server            = {}
    eks-node-monitoring-agent = {}
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
      instance_types = ["r6i.large", "m6i.large"]
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

  depends_on = [module.eks]
}

###############################################################################
# Platform (LBC, Prometheus/Grafana, Fluent Bit)
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  vpc_id                             = module.vpc.vpc_id
  aws_region                         = local.aws_region
  grafana_storage_size               = ""
  grafana_admin_password             = var.grafana_admin_password

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }

  depends_on = [module.eks]
}

###############################################################################
# Spark (Spark Operator, YuniKorn, History Server)
###############################################################################

module "spark" {
  source = "../../../modules/spark"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data

  enable_history_server     = true
  history_server_bucket     = "dev-data-platform-spark-history"
  history_server_bucket_arn = "arn:aws:s3:::dev-data-platform-spark-history"
  job_data_bucket_arns = [
    "arn:aws:s3:::dev-data-platform-spark-test",
    # Driver/executors write event logs here for the History Server to read
    "arn:aws:s3:::dev-data-platform-spark-history",
  ]

  tags = {
    Environment = "dev"
    Team        = "data-platform"
  }

  depends_on = [module.platform]
}
