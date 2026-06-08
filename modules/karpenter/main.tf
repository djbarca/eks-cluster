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

# On destroy: terminate all Karpenter-provisioned instances before the VPC
# is cleaned up. Without this, subnet deletion hangs because running instances
# hold ENIs that prevent subnet deletion.
#
# The Helm release and NodePool manifests depend on this resource so that
# during destroy Karpenter is uninstalled FIRST (preventing re-provisioning),
# then this provisioner runs and terminates remaining nodes.
resource "terraform_data" "node_cleanup" {
  input = var.cluster_name

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      INSTANCES=$(aws ec2 describe-instances \
        --filters \
          "Name=tag:karpenter.sh/discovery,Values=${self.input}" \
          "Name=instance-state-name,Values=running,pending,stopping" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text | tr '\t' ' ')
      if [ -n "$INSTANCES" ]; then
        echo "Terminating Karpenter nodes: $INSTANCES"
        aws ec2 terminate-instances --instance-ids $INSTANCES
        aws ec2 wait instance-terminated --instance-ids $INSTANCES
        echo "All Karpenter nodes terminated."
      else
        echo "No Karpenter nodes to terminate."
      fi
    EOT
  }
}
