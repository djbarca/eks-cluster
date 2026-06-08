###############################################################################
# Shared node IAM role (instance profile for all managed node groups)
###############################################################################

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "node" {
  count = length(var.node_groups) > 0 ? 1 : 0

  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = merge(local.base_tags, {
    Name         = "${var.cluster_name}-node-role"
    role-purpose = "eks-managed-node"
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = length(var.node_groups) > 0 ? toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

###############################################################################
# Launch template per node group
#
# image_id is only set when the caller explicitly pins an AMI via ami_id.
# When omitted, EKS selects the latest optimised AMI for the given ami_type
# and Kubernetes version and handles node bootstrap automatically.
# When image_id IS set, ami_type must be CUSTOM (see node group below).
###############################################################################

resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix = "${var.cluster_name}-${each.key}-"
  image_id    = each.value.ami_id

  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = local.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.base_tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.base_tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  key_name = each.value.ssh_enabled ? aws_key_pair.node[each.key].key_name : null

  tags = local.base_tags

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Managed node groups
###############################################################################

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.node[0].arn
  subnet_ids      = coalesce(each.value.subnet_ids, var.subnet_ids)

  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types

  # When a custom image_id is pinned via the launch template, EKS requires
  # ami_type = "CUSTOM". Otherwise use the caller-supplied ami_type and let
  # EKS manage AMI selection and node bootstrap.
  ami_type = each.value.ami_id != null ? "CUSTOM" : each.value.ami_type

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable_percentage = each.value.max_unavailable_percentage
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  labels = each.value.labels

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-${each.key}"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_compute,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
