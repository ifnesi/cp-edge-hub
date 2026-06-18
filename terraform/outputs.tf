output "edge_cluster_name" {
  value = aws_eks_cluster.edge.name
}

output "edge_cluster_endpoint" {
  value = aws_eks_cluster.edge.endpoint
}

output "hub_cluster_name" {
  value = aws_eks_cluster.hub.name
}

output "hub_cluster_endpoint" {
  value = aws_eks_cluster.hub.endpoint
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "kubeconfig_commands" {
  description = "Run these after terraform apply to register both clusters in your kubeconfig"
  value       = <<-EOT
    aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.edge.name} --alias edge
    aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.hub.name}  --alias hub
  EOT
}
