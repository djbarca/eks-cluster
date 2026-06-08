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
    terraform_data.node_cleanup,
  ]
}

###############################################################################
# EC2NodeClass — shared by all NodePools
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

  depends_on = [helm_release.karpenter, terraform_data.node_cleanup]
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

  depends_on = [kubectl_manifest.ec2nodeclass, terraform_data.node_cleanup]
}
