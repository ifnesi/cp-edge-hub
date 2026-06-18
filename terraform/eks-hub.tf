# =============================================================================
# EKS — Hub cluster
# (Mirrors the Edge cluster; same VPC, same IAM roles, separate node groups)
# =============================================================================

resource "aws_security_group" "hub_control_plane" {
  name        = "cp-hub-control-plane-sg"
  description = "Hub EKS control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cp-hub-control-plane-sg" }
}

resource "aws_security_group_rule" "hub_nodes_to_cp" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hub_control_plane.id
  source_security_group_id = aws_security_group.hub_nodes.id
  description              = "Nodes to control plane HTTPS"
}

resource "aws_security_group" "hub_nodes" {
  name        = "cp-hub-nodes-sg"
  description = "Hub EKS node security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.hub_control_plane.id]
  }

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka external listener"
  }

  ingress {
    from_port   = 8090
    to_port     = 8090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka REST proxy"
  }

  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Schema Registry HTTPS"
  }

  # ClusterLink is a pull (Hub brokers connect out to Edge), so this isn't
  # strictly required; kept to allow any Edge-originated traffic to Hub on 9092.
  ingress {
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.edge_nodes.id]
    description     = "Allow Edge brokers to reach Hub on 9092"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cp-hub-nodes-sg" }
}

resource "aws_eks_cluster" "hub" {
  name     = "cp-hub"
  version  = var.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # private_b is included only to meet EKS's two-AZ requirement; node groups
    # below stay on aws_subnet.private (primary AZ), so all pods run single-AZ.
    subnet_ids              = [aws_subnet.private.id, aws_subnet.private_b.id, aws_subnet.public.id]
    security_group_ids      = [aws_security_group.hub_control_plane.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = { Name = "cp-hub" }
}

resource "aws_eks_addon" "hub_ebs_csi" {
  cluster_name                = aws_eks_cluster.hub.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.37.0-eksbuild.1"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.hub_broker,
    aws_eks_node_group.hub_controller,
  ]
}

resource "aws_launch_template" "hub_broker" {
  name_prefix   = "cp-hub-broker-"
  instance_type = var.broker_instance_type

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "cp-hub-broker", Role = "broker" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "cp-hub-broker-root" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "hub_controller" {
  name_prefix   = "cp-hub-controller-"
  instance_type = var.controller_instance_type

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "cp-hub-controller", Role = "controller" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "hub_broker" {
  cluster_name    = aws_eks_cluster.hub.name
  node_group_name = "broker"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [aws_subnet.private.id]

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.hub_broker.id
    version = "$Latest"
  }

  labels = {
    role = "broker"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_readonly,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = { Name = "cp-hub-broker-ng" }
}

resource "aws_eks_node_group" "hub_controller" {
  cluster_name    = aws_eks_cluster.hub.name
  node_group_name = "controller"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [aws_subnet.private.id]

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.hub_controller.id
    version = "$Latest"
  }

  labels = {
    role = "controller"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_readonly,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = { Name = "cp-hub-controller-ng" }
}
