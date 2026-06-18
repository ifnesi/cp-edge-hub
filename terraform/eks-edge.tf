# =============================================================================
# EKS — Edge cluster
# =============================================================================

# --- Security group for the Edge control plane ---

resource "aws_security_group" "edge_control_plane" {
  name        = "cp-edge-control-plane-sg"
  description = "Edge EKS control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cp-edge-control-plane-sg" }
}

resource "aws_security_group_rule" "edge_nodes_to_cp" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.edge_control_plane.id
  source_security_group_id = aws_security_group.edge_nodes.id
  description              = "Nodes to control plane HTTPS"
}

# --- Security group for Edge nodes ---

resource "aws_security_group" "edge_nodes" {
  name        = "cp-edge-nodes-sg"
  description = "Edge EKS node security group"
  vpc_id      = aws_vpc.main.id

  # Inter-node (all traffic within the node SG)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Control plane to nodes (kubelet, metrics)
  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.edge_control_plane.id]
  }

  # NLB health checks and Kafka external traffic (9092)
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka external listener"
  }

  # REST proxy
  ingress {
    from_port   = 8090
    to_port     = 8090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka REST proxy"
  }

  # Schema Registry
  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Schema Registry HTTPS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cp-edge-nodes-sg" }
}

# --- EKS Cluster ---

resource "aws_eks_cluster" "edge" {
  name     = "cp-edge"
  version  = var.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # private_b is included only to meet EKS's two-AZ requirement; node groups
    # below stay on aws_subnet.private (primary AZ), so all pods run single-AZ.
    subnet_ids              = [aws_subnet.private.id, aws_subnet.private_b.id, aws_subnet.public.id]
    security_group_ids      = [aws_security_group.edge_control_plane.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Enable KMS envelope encryption for secrets (recommended)
  # encryption_config { ... }  # uncomment and add KMS key ARN for production

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = { Name = "cp-edge" }
}

# EBS CSI driver add-on (required for gp3 dynamic provisioning)
resource "aws_eks_addon" "edge_ebs_csi" {
  cluster_name                = aws_eks_cluster.edge.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.37.0-eksbuild.1"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.edge_broker,
    aws_eks_node_group.edge_controller,
  ]
}

# --- Launch template for broker nodes (no root disk data — EBS volumes
#     for Kafka data are provisioned dynamically by the CSI driver) ---

resource "aws_launch_template" "edge_broker" {
  name_prefix   = "cp-edge-broker-"
  instance_type = var.broker_instance_type

  # Root volume — OS only, 50 GB gp3
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
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "cp-edge-broker", Role = "broker" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "cp-edge-broker-root" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "edge_controller" {
  name_prefix   = "cp-edge-controller-"
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
    tags          = merge(var.tags, { Name = "cp-edge-controller", Role = "controller" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Node groups ---

# Broker node group — 3 nodes, one per broker pod (oneReplicaPerNode)
resource "aws_eks_node_group" "edge_broker" {
  cluster_name    = aws_eks_cluster.edge.name
  node_group_name = "broker"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [aws_subnet.private.id]

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.edge_broker.id
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

  tags = { Name = "cp-edge-broker-ng" }
}

# Controller node group — 3 nodes, hosts the KRaft controller pods.
# (Schema Registry + Control Center are pinned to the broker nodes, which have
#  spare capacity; an m5.large cannot fit a controller and an SR pod together.)
resource "aws_eks_node_group" "edge_controller" {
  cluster_name    = aws_eks_cluster.edge.name
  node_group_name = "controller"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [aws_subnet.private.id]

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.edge_controller.id
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

  tags = { Name = "cp-edge-controller-ng" }
}
