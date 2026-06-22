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

output "aws_region" {
  description = "AWS region used for all resources"
  value       = var.aws_region
}

output "producer_host_instance_id" {
  description = "SSM target for the producer/consumer EC2 host"
  value       = aws_instance.producer_host.id
}

output "producer_host_connect_command" {
  description = "Command to open an SSM session on the producer host"
  value       = "aws ssm start-session --target ${aws_instance.producer_host.id} --region ${var.aws_region}"
}

output "nat_gateway_public_ip" {
  description = "Outgoing public IP for all private-subnet workloads (EKS pods, EC2 producer). Add to Splunk HEC / firewall allowlists."
  value       = aws_eip.nat.public_ip
}

output "kubeconfig_commands" {
  description = "Run these after terraform apply to register both clusters in your kubeconfig"
  value       = <<-EOT
    aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.edge.name} --alias edge
    aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.hub.name}  --alias hub
  EOT
}
