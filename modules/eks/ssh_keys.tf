###############################################################################
# SSH key pairs — one generated per node group that sets ssh_enabled = true.
#
# IMPORTANT: tls_private_key writes the private key into Terraform STATE in
# plaintext. Protect your state backend (encrypted S3 + restricted access). By
# default the private key is also pushed to Secrets Manager so operators can
# retrieve it without reading state; disable with store_ssh_keys_in_secrets_manager.
###############################################################################

locals {
  ssh_node_groups = {
    for k, g in var.node_groups : k => g if g.ssh_enabled
  }
}

resource "tls_private_key" "node" {
  for_each = local.ssh_node_groups

  algorithm   = var.ssh_key_algorithm
  rsa_bits    = var.ssh_key_algorithm == "RSA" ? var.ssh_rsa_bits : null
  ecdsa_curve = null
}

resource "aws_key_pair" "node" {
  for_each = local.ssh_node_groups

  key_name   = "${var.cluster_name}-${each.key}"
  public_key = tls_private_key.node[each.key].public_key_openssh

  tags = merge(local.base_tags, {
    Name        = "${var.cluster_name}-${each.key}"
    key-purpose = "node-ssh"
    node-group  = each.key
  })
}

resource "aws_secretsmanager_secret" "node_ssh" {
  for_each = var.store_ssh_keys_in_secrets_manager ? local.ssh_node_groups : {}

  name        = "${var.cluster_name}/node-ssh/${each.key}"
  description = "SSH private key for ${var.cluster_name} node group ${each.key}"

  tags = merge(local.base_tags, {
    Name        = "${var.cluster_name}-${each.key}-ssh"
    key-purpose = "node-ssh"
    node-group  = each.key
  })
}

resource "aws_secretsmanager_secret_version" "node_ssh" {
  for_each = var.store_ssh_keys_in_secrets_manager ? local.ssh_node_groups : {}

  secret_id     = aws_secretsmanager_secret.node_ssh[each.key].id
  secret_string = tls_private_key.node[each.key].private_key_openssh
}

###############################################################################
# SSH ingress rule on the cluster security group
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = length(var.ssh_ingress_cidrs) > 0 ? toset(var.ssh_ingress_cidrs) : toset([])

  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "SSH to ${var.cluster_name} nodes"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-ssh"
  })
}
