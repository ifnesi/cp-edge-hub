# =============================================================================
# gp3 StorageClass — applied to both EKS clusters via separate kubernetes
# provider aliases. The EBS CSI add-on must be running first.
# =============================================================================

provider "kubernetes" {
  alias = "edge"

  host                   = aws_eks_cluster.edge.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.edge.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.edge.name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  alias = "hub"

  host                   = aws_eks_cluster.hub.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.hub.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.hub.name, "--region", var.aws_region]
  }
}

resource "kubernetes_storage_class" "gp3_edge" {
  provider = kubernetes.edge

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.edge_ebs_csi]
}

resource "kubernetes_storage_class" "gp3_hub" {
  provider = kubernetes.hub

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.hub_ebs_csi]
}
